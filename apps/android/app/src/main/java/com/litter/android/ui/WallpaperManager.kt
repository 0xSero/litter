package com.litter.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import uniffi.codex_mobile_client.ThreadKey
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import kotlin.math.cos
import kotlin.math.sin

private const val TAG = "WallpaperManager"
private const val PREFS_FILENAME = "wallpaper_prefs.json"
private const val MAX_WALLPAPER_DIMENSION = 2048
private const val PATTERN_SIZE = 1080

enum class WallpaperType {
    NONE, THEME, CUSTOM_IMAGE, SOLID_COLOR, CUSTOM_VIDEO, VIDEO_URL
}

enum class PatternType {
    DOT_GRID, DIAGONAL_LINES, CONCENTRIC_CIRCLES, HEXAGONAL_MESH, CROSS_HATCH, WAVE_LINES
}

data class WallpaperConfig(
    val type: WallpaperType = WallpaperType.NONE,
    val themeSlug: String? = null,
    val colorHex: String? = null,
    val blur: Float = 0f,
    val brightness: Float = 1f,
    val motionEnabled: Boolean = false,
    val videoURL: String? = null,
    val videoDuration: Float? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("type", type.name.lowercase())
        themeSlug?.let { put("themeSlug", it) }
        colorHex?.let { put("colorHex", it) }
        put("blur", blur.toDouble())
        put("brightness", brightness.toDouble())
        put("motionEnabled", motionEnabled)
        videoURL?.let { put("videoURL", it) }
        videoDuration?.let { put("videoDuration", it.toDouble()) }
    }

    companion object {
        fun fromJson(json: JSONObject): WallpaperConfig = WallpaperConfig(
            type = when (json.optString("type", "none")) {
                "theme" -> WallpaperType.THEME
                "custom_image" -> WallpaperType.CUSTOM_IMAGE
                "solid_color" -> WallpaperType.SOLID_COLOR
                "custom_video" -> WallpaperType.CUSTOM_VIDEO
                "video_url" -> WallpaperType.VIDEO_URL
                else -> WallpaperType.NONE
            },
            themeSlug = json.optString("themeSlug").trim().ifEmpty { null },
            colorHex = json.optString("colorHex").trim().ifEmpty { null },
            blur = json.optDouble("blur", 0.0).toFloat(),
            brightness = json.optDouble("brightness", 1.0).toFloat(),
            motionEnabled = json.optBoolean("motionEnabled", false),
            videoURL = json.optString("videoURL").trim().ifEmpty { null },
            videoDuration = if (json.has("videoDuration")) json.optDouble("videoDuration").toFloat() else null,
        )
    }
}

sealed class WallpaperScope {
    data class Thread(val key: ThreadKey) : WallpaperScope()
    data class Server(val serverId: String) : WallpaperScope()
    data object Pending : WallpaperScope()
}

object WallpaperManager {
    private var appContext: Context? = null
    private var initialized = false
    private var prefsData = JSONObject()
    private val bitmapCache = LinkedHashMap<String, Bitmap>(8, 0.75f, true)

    var activeThreadKey by mutableStateOf<ThreadKey?>(null)

    // Transient config set by selection screen, consumed by adjust screen
    var pendingConfig by mutableStateOf<WallpaperConfig?>(null)

    // Incremented on every setWallpaper/clear to trigger recomposition in observers
    var version by mutableStateOf(0)
        private set

    var resolvedBitmap by mutableStateOf<Bitmap?>(null)
        private set

    var resolvedConfig by mutableStateOf<WallpaperConfig?>(null)
        private set

    val isWallpaperSet: Boolean
        get() = resolvedConfig?.type?.let { it != WallpaperType.NONE } == true

    fun initialize(context: Context) {
        if (initialized) return
        appContext = context.applicationContext
        loadPrefs()
        initialized = true
    }

    fun resolvedConfig(threadKey: ThreadKey?): WallpaperConfig? {
        if (threadKey == null) return null
        val threadScopeKey = "${threadKey.serverId}::${threadKey.threadId}"
        val threads = prefsData.optJSONObject("threads")
        val threadConfig = threads?.optJSONObject(threadScopeKey)
        if (threadConfig != null) return WallpaperConfig.fromJson(threadConfig)
        val servers = prefsData.optJSONObject("servers")
        val serverConfig = servers?.optJSONObject(threadKey.serverId)
        if (serverConfig != null) return WallpaperConfig.fromJson(serverConfig)
        return null
    }

    fun resolvedConfigForServer(serverId: String): WallpaperConfig? {
        val servers = prefsData.optJSONObject("servers")
        val serverConfig = servers?.optJSONObject(serverId)
        if (serverConfig != null) return WallpaperConfig.fromJson(serverConfig)
        return null
    }

    fun resolvedScope(threadKey: ThreadKey?): WallpaperScope? {
        if (threadKey == null) return null
        val threads = prefsData.optJSONObject("threads")
        val threadScopeKey = "${threadKey.serverId}::${threadKey.threadId}"
        if (threads?.optJSONObject(threadScopeKey) != null) {
            return WallpaperScope.Thread(threadKey)
        }
        val servers = prefsData.optJSONObject("servers")
        if (servers?.optJSONObject(threadKey.serverId) != null) {
            return WallpaperScope.Server(threadKey.serverId)
        }
        return null
    }

    fun resolvedScopeForServer(serverId: String): WallpaperScope? {
        val servers = prefsData.optJSONObject("servers")
        return if (servers?.optJSONObject(serverId) != null) {
            WallpaperScope.Server(serverId)
        } else {
            null
        }
    }

    fun setWallpaper(config: WallpaperConfig, scope: WallpaperScope) {
        if (scope == WallpaperScope.Pending) {
            pendingConfig = config
            return
        }
        when (scope) {
            is WallpaperScope.Thread -> {
                val key = "${scope.key.serverId}::${scope.key.threadId}"
                val threads = prefsData.optJSONObject("threads") ?: JSONObject()
                threads.put(key, config.toJson())
                prefsData.put("threads", threads)
            }
            is WallpaperScope.Server -> {
                val servers = prefsData.optJSONObject("servers") ?: JSONObject()
                servers.put(scope.serverId, config.toJson())
                prefsData.put("servers", servers)
            }
            WallpaperScope.Pending -> Unit
        }
        savePrefs()
        refreshResolved()
        version++
    }

    fun clearWallpaper(scope: WallpaperScope) {
        if (scope == WallpaperScope.Pending) {
            clearPendingWallpaper()
            return
        }
        when (scope) {
            is WallpaperScope.Thread -> {
                val key = "${scope.key.serverId}::${scope.key.threadId}"
                prefsData.optJSONObject("threads")?.remove(key)
                // Also remove custom image and video files
                imageFileForScope(scope)?.delete()
                videoFileForScope(scope)?.delete()
            }
            is WallpaperScope.Server -> {
                prefsData.optJSONObject("servers")?.remove(scope.serverId)
                imageFileForScope(scope)?.delete()
                videoFileForScope(scope)?.delete()
            }
            WallpaperScope.Pending -> Unit
        }
        savePrefs()
        refreshResolved()
        version++
    }

    fun clearPendingWallpaper() {
        pendingConfig = null
        imageFileForScope(WallpaperScope.Pending)?.delete()
        videoFileForScope(WallpaperScope.Pending)?.delete()
        thumbnailFileForScope(WallpaperScope.Pending)?.delete()
    }

    suspend fun stagePendingImageFromUri(uri: Uri): Boolean {
        val bitmap = decodeBitmap(appContext ?: return false, uri) ?: return false
        val file = imageFileForScope(WallpaperScope.Pending) ?: return false
        val wrote = withContext(Dispatchers.IO) {
            runCatching {
                file.parentFile?.mkdirs()
                FileOutputStream(file).use { stream ->
                    check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, stream))
                    stream.fd.sync()
                }
            }.onFailure { Log.e(TAG, "Failed to write pending wallpaper image", it) }.isSuccess
        }
        if (!wrote) return false
        pendingConfig = WallpaperConfig(type = WallpaperType.CUSTOM_IMAGE)
        return true
    }

    fun previewBitmapForConfig(
        config: WallpaperConfig,
        threadKey: ThreadKey? = null,
        serverId: String? = null,
    ): Bitmap? {
        if (pendingConfig == config && config.type == WallpaperType.CUSTOM_IMAGE) {
            val pendingFile = imageFileForScope(WallpaperScope.Pending)
            if (pendingFile?.exists() == true) {
                return decodeBitmapFile(pendingFile)
            }
        }
        return resolvedBitmapForConfig(config, threadKey = threadKey, serverId = serverId)
    }

    fun previewVideoPathForConfig(
        config: WallpaperConfig,
        threadKey: ThreadKey? = null,
        serverId: String? = null,
    ): String? {
        if (pendingConfig == config &&
            (config.type == WallpaperType.CUSTOM_VIDEO || config.type == WallpaperType.VIDEO_URL)
        ) {
            val pendingFile = videoFileForScope(WallpaperScope.Pending)
            if (pendingFile?.exists() == true) {
                return pendingFile.absolutePath
            }
        }
        return if (threadKey != null) {
            videoFilePath(threadKey)
        } else {
            serverId?.let(::videoFilePathForServer)
        }
    }

    fun applyWallpaper(
        config: WallpaperConfig,
        targetScope: WallpaperScope,
        sourceScope: WallpaperScope? = null,
    ): Boolean {
        if (targetScope == WallpaperScope.Pending) {
            pendingConfig = config
            return true
        }

        when (config.type) {
            WallpaperType.CUSTOM_IMAGE -> {
                val source = imageFileForScope(WallpaperScope.Pending)
                    ?.takeIf(File::exists)
                    ?: sourceScope?.let(::imageFileForScope)?.takeIf(File::exists)
                val target = imageFileForScope(targetScope)
                if (source != null && target != null && source.absolutePath != target.absolutePath) {
                    copyFile(source, target) ?: return false
                } else if (source == null && target?.exists() != true) {
                    return false
                }
            }
            WallpaperType.CUSTOM_VIDEO, WallpaperType.VIDEO_URL -> {
                val source = videoFileForScope(WallpaperScope.Pending)
                    ?.takeIf(File::exists)
                    ?: sourceScope?.let(::videoFileForScope)?.takeIf(File::exists)
                val target = videoFileForScope(targetScope)
                if (source != null && target != null && source.absolutePath != target.absolutePath) {
                    copyFile(source, target) ?: return false
                } else if (source == null && target?.exists() != true) {
                    return false
                }

                val sourceThumb = thumbnailFileForScope(WallpaperScope.Pending)
                    ?.takeIf(File::exists)
                    ?: sourceScope?.let(::thumbnailFileForScope)?.takeIf(File::exists)
                val targetThumb = thumbnailFileForScope(targetScope)
                if (sourceThumb != null && targetThumb != null && sourceThumb.absolutePath != targetThumb.absolutePath) {
                    copyFile(sourceThumb, targetThumb)
                }
            }
            else -> Unit
        }

        setWallpaper(config, targetScope)
        clearPendingWallpaper()
        return true
    }

    fun setActiveThread(key: ThreadKey?) {
        activeThreadKey = key
        refreshResolved()
    }

    suspend fun setCustomFromUri(uri: Uri): Boolean {
        val scope = activeScope() ?: return false
        return setCustomImageFromUri(uri, scope)
    }

    fun clear() {
        val scope = activeScope() ?: return
        clearWallpaper(scope)
    }

    suspend fun setCustomImageFromUri(uri: Uri, scope: WallpaperScope): Boolean {
        val context = appContext ?: return false
        val bitmap = decodeBitmap(context, uri) ?: return false
        val file = imageFileForScope(scope) ?: return false
        val wrote = withContext(Dispatchers.IO) {
            runCatching {
                file.parentFile?.mkdirs()
                FileOutputStream(file).use { stream ->
                    check(bitmap.compress(Bitmap.CompressFormat.JPEG, 85, stream))
                    stream.fd.sync()
                }
            }.onFailure { Log.e(TAG, "Failed to write wallpaper image", it) }.isSuccess
        }
        if (!wrote) return false

        val config = WallpaperConfig(type = WallpaperType.CUSTOM_IMAGE)
        setWallpaper(config, scope)
        return true
    }

    fun generatePatternBitmap(
        background: Color,
        accent: Color,
        patternType: PatternType,
    ): Bitmap {
        val cacheKey = "${background.toArgb()}_${accent.toArgb()}_${patternType.name}"
        bitmapCache[cacheKey]?.let { return it }

        val bitmap = Bitmap.createBitmap(PATTERN_SIZE, PATTERN_SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val bgPaint = Paint().apply { color = background.toArgb() }
        canvas.drawRect(0f, 0f, PATTERN_SIZE.toFloat(), PATTERN_SIZE.toFloat(), bgPaint)

        val patternPaint = Paint().apply {
            color = accent.toArgb()
            alpha = 25 // ~10% opacity
            isAntiAlias = true
            style = Paint.Style.STROKE
            strokeWidth = 1.5f
        }
        val fillPaint = Paint().apply {
            color = accent.toArgb()
            alpha = 20
            isAntiAlias = true
            style = Paint.Style.FILL
        }

        val size = PATTERN_SIZE.toFloat()
        when (patternType) {
            PatternType.DOT_GRID -> {
                val spacing = 24f
                var x = spacing
                while (x < size) {
                    var y = spacing
                    while (y < size) {
                        canvas.drawCircle(x, y, 1.5f, fillPaint)
                        y += spacing
                    }
                    x += spacing
                }
            }
            PatternType.DIAGONAL_LINES -> {
                val spacing = 20f
                var offset = -size
                while (offset < size * 2) {
                    canvas.drawLine(offset, 0f, offset + size, size, patternPaint)
                    offset += spacing
                }
            }
            PatternType.CONCENTRIC_CIRCLES -> {
                val cx = size / 2
                val cy = size / 2
                var r = 30f
                while (r < size) {
                    canvas.drawCircle(cx, cy, r, patternPaint)
                    r += 40f
                }
            }
            PatternType.HEXAGONAL_MESH -> {
                val hexSize = 30f
                val w = hexSize * 1.732f
                val h = hexSize * 2f
                var row = 0
                var y = 0f
                while (y < size + h) {
                    var x = if (row % 2 == 0) 0f else w / 2f
                    while (x < size + w) {
                        drawHexagon(canvas, x, y, hexSize, patternPaint)
                        x += w
                    }
                    y += h * 0.75f
                    row++
                }
            }
            PatternType.CROSS_HATCH -> {
                val spacing = 20f
                var pos = 0f
                while (pos < size) {
                    canvas.drawLine(pos, 0f, pos, size, patternPaint)
                    canvas.drawLine(0f, pos, size, pos, patternPaint)
                    pos += spacing
                }
            }
            PatternType.WAVE_LINES -> {
                val amplitude = 15f
                val wavelength = 60f
                var y = 20f
                while (y < size) {
                    val path = android.graphics.Path()
                    path.moveTo(0f, y)
                    var x = 0f
                    while (x < size) {
                        val nextX = x + wavelength / 4f
                        val controlY = y + if (((x / (wavelength / 2f)).toInt() % 2) == 0) -amplitude else amplitude
                        path.quadTo(x + wavelength / 8f, controlY, nextX, y)
                        x = nextX
                    }
                    canvas.drawPath(path, patternPaint)
                    y += 30f
                }
            }
        }

        bitmapCache[cacheKey] = bitmap
        return bitmap
    }

    fun patternTypeForIndex(index: Int): PatternType {
        val types = PatternType.entries
        return types[index % types.size]
    }

    fun videoFilePath(scope: WallpaperScope): String? {
        val file = videoFileForScope(scope) ?: return null
        return if (file.exists()) file.absolutePath else null
    }

    fun videoFilePathForServer(serverId: String): String? {
        return videoFilePath(WallpaperScope.Server(serverId))
    }

    fun videoFilePath(threadKey: ThreadKey?): String? {
        if (threadKey == null) return null
        // Try thread-scoped first
        val threadPath = videoFilePath(WallpaperScope.Thread(threadKey))
        if (threadPath != null) return threadPath
        // Fall back to server-scoped
        return videoFilePath(WallpaperScope.Server(threadKey.serverId))
    }

    fun videoFileForScope(scope: WallpaperScope): File? {
        val context = appContext ?: return null
        return File(context.filesDir, "wallpaper_${fileKeyForScope(scope)}.mp4")
    }

    fun resolvedBitmapForConfig(config: WallpaperConfig, threadKey: ThreadKey?): Bitmap? {
        return resolvedBitmapForConfig(config, threadKey = threadKey, serverId = threadKey?.serverId)
    }

    fun resolvedBitmapForConfig(config: WallpaperConfig, threadKey: ThreadKey? = null, serverId: String? = null): Bitmap? {
        val resolvedServerId = threadKey?.serverId ?: serverId
        return when (config.type) {
            WallpaperType.NONE -> null
            WallpaperType.CUSTOM_VIDEO, WallpaperType.VIDEO_URL -> null // Video handled by player
            WallpaperType.THEME -> {
                val slug = config.themeSlug ?: return null
                val entry = LitterThemeManager.themeIndex.find { it.slug == slug } ?: return null
                val bg = colorFromHex(entry.backgroundHex)
                val accent = colorFromHex(entry.accentHex)
                val patternIndex = LitterThemeManager.themeIndex.indexOf(entry)
                generatePatternBitmap(bg, accent, patternTypeForIndex(patternIndex))
            }
            WallpaperType.CUSTOM_IMAGE -> {
                val context = appContext ?: return null
                if (threadKey != null) {
                    val fileKey = "${threadKey.serverId}_${threadKey.threadId}"
                    val file = File(context.filesDir, "wallpaper_$fileKey.jpg")
                    if (!file.exists()) {
                        // Try server-scoped
                        val serverFile = File(context.filesDir, "wallpaper_server_${threadKey.serverId}.jpg")
                        if (serverFile.exists()) {
                            decodeBitmapFile(serverFile)
                        } else null
                    } else {
                        decodeBitmapFile(file)
                    }
                } else if (resolvedServerId != null) {
                    val serverFile = File(context.filesDir, "wallpaper_server_${resolvedServerId}.jpg")
                    if (serverFile.exists()) {
                        decodeBitmapFile(serverFile)
                    } else null
                } else {
                    null
                }
            }
            WallpaperType.SOLID_COLOR -> null // Solid color is handled via Compose background
        }
    }

    fun cleanup(knownServerIds: Set<String>, knownThreadKeys: Set<String>) {
        val threads = prefsData.optJSONObject("threads")
        if (threads != null) {
            val keysToRemove = mutableListOf<String>()
            val iter = threads.keys()
            while (iter.hasNext()) {
                val key = iter.next()
                if (key !in knownThreadKeys) keysToRemove.add(key)
            }
            keysToRemove.forEach { threads.remove(it) }
        }
        val servers = prefsData.optJSONObject("servers")
        if (servers != null) {
            val keysToRemove = mutableListOf<String>()
            val iter = servers.keys()
            while (iter.hasNext()) {
                val key = iter.next()
                if (key !in knownServerIds) keysToRemove.add(key)
            }
            keysToRemove.forEach { servers.remove(it) }
        }
        savePrefs()
        // Clean orphaned image and video files
        val context = appContext ?: return
        context.filesDir.listFiles()?.filter {
            it.name.startsWith("wallpaper_") && (it.name.endsWith(".jpg") || it.name.endsWith(".mp4"))
        }?.forEach { file ->
            val name = file.nameWithoutExtension.removePrefix("wallpaper_")
            val isThreadFile = knownThreadKeys.any { key ->
                val parts = key.split("::")
                if (parts.size == 2) name == "${parts[0]}_${parts[1]}" else false
            }
            val isServerFile = knownServerIds.any { name == "server_$it" }
            if (!isThreadFile && !isServerFile) file.delete()
        }
    }

    fun refreshResolved() {
        val key = activeThreadKey
        val config = resolvedConfig(key)
        resolvedConfig = config
        resolvedBitmap = if (config != null) resolvedBitmapForConfig(config, key) else null
    }

    private fun loadPrefs() {
        val context = appContext ?: return
        val file = File(context.filesDir, PREFS_FILENAME)
        if (file.exists()) {
            prefsData = runCatching {
                JSONObject(file.readText())
            }.getOrElse {
                Log.w(TAG, "Failed to parse wallpaper prefs", it)
                JSONObject()
            }
        }
    }

    private fun savePrefs() {
        val context = appContext ?: return
        val file = File(context.filesDir, PREFS_FILENAME)
        runCatching {
            file.writeText(prefsData.toString(2))
        }.onFailure {
            Log.e(TAG, "Failed to save wallpaper prefs", it)
        }
    }

    private fun imageFileForScope(scope: WallpaperScope): File? {
        val context = appContext ?: return null
        return File(context.filesDir, "wallpaper_${fileKeyForScope(scope)}.jpg")
    }

    private fun activeScope(): WallpaperScope? {
        val key = activeThreadKey ?: return null
        return WallpaperScope.Thread(key)
    }

    private fun thumbnailFileForScope(scope: WallpaperScope): File? {
        val context = appContext ?: return null
        return File(context.filesDir, "wallpaper_${fileKeyForScope(scope)}_thumb.jpg")
    }

    private fun fileKeyForScope(scope: WallpaperScope): String =
        when (scope) {
            is WallpaperScope.Thread -> "${scope.key.serverId}_${scope.key.threadId}"
            is WallpaperScope.Server -> "server_${scope.serverId}"
            WallpaperScope.Pending -> "pending"
        }

    private fun copyFile(source: File, dest: File): File? =
        runCatching {
            dest.parentFile?.mkdirs()
            source.inputStream().use { input ->
                FileOutputStream(dest).use { output ->
                    input.copyTo(output)
                    output.fd.sync()
                }
            }
            dest
        }.onFailure {
            Log.e(TAG, "Failed to copy wallpaper asset from ${source.absolutePath} to ${dest.absolutePath}", it)
        }.getOrNull()

    private fun drawHexagon(canvas: Canvas, cx: Float, cy: Float, size: Float, paint: Paint) {
        val path = android.graphics.Path()
        for (i in 0 until 6) {
            val angle = Math.toRadians((60.0 * i) - 30.0)
            val x = cx + size * cos(angle).toFloat()
            val y = cy + size * sin(angle).toFloat()
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        canvas.drawPath(path, paint)
    }

    private suspend fun decodeBitmap(context: Context, uri: Uri): Bitmap? =
        withContext(Dispatchers.IO) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                runCatching {
                    val source = ImageDecoder.createSource(context.contentResolver, uri)
                    ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                        val size = info.size
                        val largest = maxOf(size.width, size.height)
                        if (largest > MAX_WALLPAPER_DIMENSION) {
                            val scale = MAX_WALLPAPER_DIMENSION.toFloat() / largest.toFloat()
                            decoder.setTargetSize(
                                (size.width * scale).toInt().coerceAtLeast(1),
                                (size.height * scale).toInt().coerceAtLeast(1),
                            )
                        }
                    }
                }.onFailure {
                    Log.w(TAG, "ImageDecoder failed for uri=$uri", it)
                }.getOrNull()?.let { return@withContext it }
            }

            decodeSampledBitmap { context.contentResolver.openInputStream(uri) }
        }

    private fun decodeBitmapFile(file: File): Bitmap? = decodeSampledBitmap { file.inputStream() }

    internal fun decodeSampledBitmap(openStream: () -> InputStream?): Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            val input = openStream() ?: return null
            // A bounds-only decode intentionally returns null; its dimensions are the result.
            input.use { BitmapFactory.decodeStream(it, null, bounds) }
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

            val options = BitmapFactory.Options().apply {
                inSampleSize = calculateInSampleSize(bounds.outWidth, bounds.outHeight)
            }
            openStream()?.use { BitmapFactory.decodeStream(it, null, options) }
        } catch (error: Exception) {
            Log.w(TAG, "Failed to decode wallpaper", error)
            null
        }
    }

    private fun calculateInSampleSize(width: Int, height: Int): Int {
        var sampleSize = 1
        if (width <= 0 || height <= 0) return sampleSize
        while (width.toLong() > MAX_WALLPAPER_DIMENSION.toLong() * sampleSize ||
            height.toLong() > MAX_WALLPAPER_DIMENSION.toLong() * sampleSize
        ) {
            sampleSize *= 2
        }
        return sampleSize
    }
}
