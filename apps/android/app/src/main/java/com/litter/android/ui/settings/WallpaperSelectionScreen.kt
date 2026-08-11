package com.litter.android.ui.settings

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterThemeIndexEntry
import com.litter.android.ui.LitterThemeManager
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import com.litter.android.ui.VideoWallpaperProcessor
import com.litter.android.ui.VideoWallpaperPlayer
import com.litter.android.ui.WallpaperConfig
import com.litter.android.ui.WallpaperManager
import com.litter.android.ui.WallpaperScope
import com.litter.android.ui.WallpaperType
import com.litter.android.ui.colorFromHex
import com.litter.android.ui.rememberWallpaperMotionTransform
import com.litter.android.ui.wallpaperBlurRadius
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.ThreadKey

@Composable
fun WallpaperSelectionScreen(
    threadKey: ThreadKey? = null,
    serverId: String? = null,
    onBack: () -> Unit,
    onApplied: () -> Unit,
) {
    val isServerOnly = threadKey == null
    val resolvedServerId = threadKey?.serverId ?: serverId
    val wallpaperScope: WallpaperScope? = if (threadKey != null) WallpaperScope.Thread(threadKey)
        else resolvedServerId?.let { WallpaperScope.Server(it) }
    val sourceScope: WallpaperScope? = if (threadKey != null) {
        WallpaperManager.resolvedScope(threadKey)
    } else {
        resolvedServerId?.let { WallpaperManager.resolvedScopeForServer(it) }
    }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val themes = LitterThemeManager.themeIndex
    var previewConfig by remember {
        mutableStateOf(
            WallpaperManager.pendingConfig ?: if (threadKey != null) WallpaperManager.resolvedConfig(threadKey)
            else resolvedServerId?.let { WallpaperManager.resolvedConfigForServer(it) }
        )
    }
    var sourceOptionsExpanded by remember { mutableStateOf(false) }
    var sheetMinimized by remember { mutableStateOf(false) }
    var isProcessingVideo by remember { mutableStateOf(false) }
    var videoUrlText by remember { mutableStateOf("") }

    val photoPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri: Uri? ->
            if (uri != null) {
            scope.launch {
                val success = WallpaperManager.stagePendingImageFromUri(uri)
                if (success) {
                    val config = WallpaperConfig(type = WallpaperType.CUSTOM_IMAGE)
                    WallpaperManager.pendingConfig = config
                    previewConfig = config
                }
            }
        }
    }

    val videoPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri: Uri? ->
        if (uri != null) {
            isProcessingVideo = true
            scope.launch {
                val result = VideoWallpaperProcessor.processLocalVideo(context, uri, WallpaperScope.Pending)
                if (result != null) {
                    val config = WallpaperConfig(type = WallpaperType.CUSTOM_VIDEO, videoDuration = result.durationSeconds)
                    WallpaperManager.pendingConfig = config
                    previewConfig = config
                    isProcessingVideo = false
                } else {
                    isProcessingVideo = false
                }
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize().background(LitterTheme.background)) {
        // Full-screen preview
        val previewBitmap = remember(previewConfig) {
            previewConfig?.let { WallpaperManager.previewBitmapForConfig(it, threadKey = threadKey, serverId = resolvedServerId) }
        }
        val previewVideoPath = previewConfig?.let {
            WallpaperManager.previewVideoPathForConfig(it, threadKey = threadKey, serverId = resolvedServerId)
        }
        var blur by remember(previewConfig) { mutableFloatStateOf(previewConfig?.blur ?: 0f) }
        var brightness by remember(previewConfig) { mutableFloatStateOf(previewConfig?.brightness ?: 1f) }
        var motionEnabled by remember(previewConfig) { mutableStateOf(previewConfig?.motionEnabled ?: false) }
        val blurRadius = wallpaperBlurRadius(blur)
        val brightnessAlpha = brightness.coerceIn(0f, 1f)
        val motion = rememberWallpaperMotionTransform(motionEnabled)
        val selectedLabel = when (previewConfig?.type) {
            WallpaperType.CUSTOM_IMAGE -> "Photo"
            WallpaperType.CUSTOM_VIDEO -> "Video"
            WallpaperType.VIDEO_URL -> "Video URL"
            WallpaperType.SOLID_COLOR -> "Color"
            WallpaperType.THEME -> themes.firstOrNull { it.slug == previewConfig?.themeSlug }?.name ?: "Theme"
            WallpaperType.NONE, null -> "No wallpaper"
        }

        if (previewConfig?.type in setOf(WallpaperType.CUSTOM_VIDEO, WallpaperType.VIDEO_URL) && previewVideoPath != null) {
            VideoWallpaperPlayer(
                filePath = previewVideoPath,
                blurAmount = blur,
                brightnessAlpha = brightnessAlpha,
                motionTransform = motion,
                modifier = Modifier.fillMaxSize(),
            )
        } else if (previewBitmap != null) {
            Image(
                bitmap = previewBitmap.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxSize()
                    .blur(blurRadius)
                    .graphicsLayer {
                        alpha = brightnessAlpha
                        scaleX = motion.scale
                        scaleY = motion.scale
                        translationX = motion.translationX
                        translationY = motion.translationY
                    },
            )
        } else if (previewConfig?.type == WallpaperType.SOLID_COLOR) {
            val color = previewConfig?.colorHex?.let { colorFromHex(it) } ?: LitterTheme.background
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(color)
                    .graphicsLayer { alpha = brightnessAlpha },
            )
        } else {
            Box(modifier = Modifier.fillMaxSize().background(LitterTheme.background))
        }

        // Sample bubbles overlay
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.TopCenter)
                .padding(start = 32.dp, end = 32.dp, top = 104.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SampleBubble(
                text = "Can you help me refactor this module?",
                isUser = true,
            )
            SampleBubble(
                text = "Sure! I'll analyze the code structure and suggest improvements.",
                isUser = false,
            )
        }

        // Top bar
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .background(LitterTheme.surface.copy(alpha = 0.85f))
                .padding(horizontal = 8.dp, vertical = 6.dp),
        ) {
            IconButton(onClick = onBack, modifier = Modifier.size(32.dp)) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = LitterTheme.textPrimary,
                    modifier = Modifier.size(20.dp),
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = "Select Wallpaper",
                color = LitterTheme.textPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }

        // Bottom card
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .background(
                    LitterTheme.surface.copy(alpha = 0.95f),
                    RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
                )
                .animateContentSize()
                .padding(16.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .width(40.dp)
                        .height(4.dp)
                        .clip(CircleShape)
                        .background(LitterTheme.textMuted.copy(alpha = 0.5f)),
                )
                Spacer(Modifier.weight(1f))
                IconButton(onClick = { sheetMinimized = !sheetMinimized }, modifier = Modifier.size(32.dp)) {
                    Icon(
                        imageVector = if (sheetMinimized) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        contentDescription = if (sheetMinimized) "Expand controls" else "Minimize controls",
                        tint = LitterTheme.textPrimary,
                    )
                }
            }

            Spacer(Modifier.height(10.dp))

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { sheetMinimized = !sheetMinimized },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Wallpaper Controls",
                        color = LitterTheme.textPrimary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = if (sheetMinimized) {
                            "$selectedLabel selected. Tap to expand controls."
                        } else {
                            "$selectedLabel selected. Adjust it here, or expand below to pick something new."
                        },
                        color = LitterTheme.textMuted,
                        fontSize = 12.sp,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Icon(
                    imageVector = if (sheetMinimized) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (sheetMinimized) "Expand controls" else "Minimize controls",
                    tint = LitterTheme.textPrimary,
                )
            }

            if (!sheetMinimized) {
                Spacer(Modifier.height(12.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(24.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(
                            checked = blur > 0.01f,
                            onCheckedChange = { checked ->
                                blur = if (checked) 0.75f else 0f
                                previewConfig = (previewConfig ?: WallpaperConfig(type = WallpaperType.NONE)).copy(
                                    blur = blur,
                                    brightness = brightness,
                                    motionEnabled = motionEnabled,
                                )
                            },
                            colors = CheckboxDefaults.colors(
                                checkedColor = LitterTheme.accent,
                                uncheckedColor = LitterTheme.textMuted,
                            ),
                        )
                        Text("Blurred", color = LitterTheme.textPrimary, fontSize = 13.sp)
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(
                            checked = motionEnabled,
                            onCheckedChange = {
                                motionEnabled = it
                                previewConfig = (previewConfig ?: WallpaperConfig(type = WallpaperType.NONE)).copy(
                                    blur = blur,
                                    brightness = brightness,
                                    motionEnabled = motionEnabled,
                                )
                            },
                            colors = CheckboxDefaults.colors(
                                checkedColor = LitterTheme.accent,
                                uncheckedColor = LitterTheme.textMuted,
                            ),
                        )
                        Text("Motion", color = LitterTheme.textPrimary, fontSize = 13.sp)
                    }
                }

                Spacer(Modifier.height(12.dp))

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("\u2600", fontSize = 14.sp, color = LitterTheme.textMuted)
                    Slider(
                        value = brightness,
                        onValueChange = {
                            brightness = it
                            previewConfig = (previewConfig ?: WallpaperConfig(type = WallpaperType.NONE)).copy(
                                blur = blur,
                                brightness = brightness,
                                motionEnabled = motionEnabled,
                            )
                        },
                        valueRange = 0.2f..1f,
                        modifier = Modifier
                            .weight(1f)
                            .padding(horizontal = 8.dp),
                        colors = SliderDefaults.colors(
                            thumbColor = LitterTheme.accent,
                            activeTrackColor = LitterTheme.accent,
                            inactiveTrackColor = LitterTheme.border,
                        ),
                    )
                    Text("\u2600", fontSize = 20.sp, color = LitterTheme.textPrimary)
                }

                Spacer(Modifier.height(16.dp))

                if (threadKey != null) {
                    Button(
                        onClick = {
                            val config = (previewConfig ?: WallpaperConfig(type = WallpaperType.NONE)).copy(
                                blur = blur,
                                brightness = brightness,
                                motionEnabled = motionEnabled,
                            )
                            if (config.type == WallpaperType.NONE) {
                                WallpaperManager.clearPendingWallpaper()
                                WallpaperManager.clearWallpaper(WallpaperScope.Thread(threadKey))
                                onApplied()
                            } else if (WallpaperManager.applyWallpaper(
                                    config,
                                    WallpaperScope.Thread(threadKey),
                                    sourceScope,
                                )
                            ) {
                                onApplied()
                            }
                        },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = LitterTheme.accent,
                            contentColor = LitterTheme.onAccentStrong,
                        ),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Apply for This Thread", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }

                    Spacer(Modifier.height(8.dp))
                }

                if (resolvedServerId != null) {
                    Button(
                        onClick = {
                            val config = (previewConfig ?: WallpaperConfig(type = WallpaperType.NONE)).copy(
                                blur = blur,
                                brightness = brightness,
                                motionEnabled = motionEnabled,
                            )
                            if (config.type == WallpaperType.NONE) {
                                WallpaperManager.clearPendingWallpaper()
                                WallpaperManager.clearWallpaper(WallpaperScope.Server(resolvedServerId))
                                onApplied()
                            } else if (WallpaperManager.applyWallpaper(
                                    config,
                                    WallpaperScope.Server(resolvedServerId),
                                    sourceScope,
                                )
                            ) {
                                onApplied()
                            }
                        },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (isServerOnly) LitterTheme.accent else LitterTheme.surface,
                            contentColor = if (isServerOnly) LitterTheme.onAccentStrong else LitterTheme.textPrimary,
                        ),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            "Apply for This Server",
                            fontSize = 13.sp,
                            fontWeight = if (isServerOnly) FontWeight.SemiBold else FontWeight.Normal,
                        )
                    }
                }

                Spacer(Modifier.height(12.dp))
                HorizontalDivider(color = LitterTheme.border.copy(alpha = 0.3f))
                Spacer(Modifier.height(6.dp))

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { sourceOptionsExpanded = !sourceOptionsExpanded }
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Choose a Different Wallpaper",
                            color = LitterTheme.textPrimary,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium,
                        )
                        Text(
                            text = "Themes, photos, colors, videos, and URL sources",
                            color = LitterTheme.textMuted,
                            fontSize = 12.sp,
                        )
                    }
                    Icon(
                        imageVector = if (sourceOptionsExpanded) Icons.Default.ExpandMore else Icons.Default.ExpandLess,
                        contentDescription = if (sourceOptionsExpanded) "Collapse wallpaper sources" else "Expand wallpaper sources",
                        tint = LitterTheme.textPrimary,
                    )
                }

                if (sourceOptionsExpanded) {
                    Spacer(Modifier.height(10.dp))

                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 280.dp)
                            .verticalScroll(rememberScrollState()),
                    ) {
                        Text(
                            text = "Themes",
                            color = LitterTheme.textPrimary,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Spacer(Modifier.height(12.dp))

                        LazyRow(
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            contentPadding = PaddingValues(horizontal = 4.dp),
                        ) {
                            item {
                                ThemeThumbnail(
                                    label = "None",
                                    backgroundColor = LitterTheme.background,
                                    accentColor = null,
                                    isSelected = previewConfig == null || previewConfig?.type == WallpaperType.NONE,
                                    isNone = true,
                                    onClick = {
                                        WallpaperManager.clearPendingWallpaper()
                                        previewConfig = null
                                        wallpaperScope?.let { WallpaperManager.clearWallpaper(it) }
                                    },
                                )
                            }

                            items(themes) { theme ->
                                val bg = colorFromHex(theme.backgroundHex)
                                val accent = colorFromHex(theme.accentHex)
                                ThemeThumbnail(
                                    label = theme.name,
                                    backgroundColor = bg,
                                    accentColor = accent,
                                    isSelected = previewConfig?.themeSlug == theme.slug,
                                    onClick = {
                                        val config = WallpaperConfig(
                                            type = WallpaperType.THEME,
                                            themeSlug = theme.slug,
                                            blur = blur,
                                            brightness = brightness,
                                            motionEnabled = motionEnabled,
                                        )
                                        previewConfig = config
                                        WallpaperManager.pendingConfig = config
                                    },
                                )
                            }
                        }

                        Spacer(Modifier.height(16.dp))

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            TextButton(
                                onClick = {
                                    photoPicker.launch(
                                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                    )
                                },
                                modifier = Modifier.weight(1f),
                            ) {
                                Icon(
                                    Icons.Default.Image,
                                    contentDescription = null,
                                    tint = LitterTheme.accent,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    "Choose Photo",
                                    color = LitterTheme.accent,
                                    fontSize = 13.sp,
                                )
                            }

                            TextButton(
                                onClick = {
                                    val hex = String.format("#%06X", 0xFFFFFF and LitterTheme.accent.toArgb())
                                    val config = WallpaperConfig(
                                        type = WallpaperType.SOLID_COLOR,
                                        colorHex = hex,
                                        blur = blur,
                                        brightness = brightness,
                                        motionEnabled = motionEnabled,
                                    )
                                    previewConfig = config
                                    WallpaperManager.pendingConfig = config
                                },
                                modifier = Modifier.weight(1f),
                            ) {
                                Icon(
                                    Icons.Default.Palette,
                                    contentDescription = null,
                                    tint = LitterTheme.accent,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    "Set a Color",
                                    color = LitterTheme.accent,
                                    fontSize = 13.sp,
                                )
                            }
                        }

                        Spacer(Modifier.height(8.dp))
                        HorizontalDivider(color = LitterTheme.border.copy(alpha = 0.3f))
                        Spacer(Modifier.height(8.dp))

                        TextButton(
                            onClick = {
                                videoPicker.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly),
                                )
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Icon(
                                Icons.Default.PlayCircle,
                                contentDescription = null,
                                tint = LitterTheme.accent,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text("Choose Video", color = LitterTheme.accent, fontSize = 13.sp)
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                Icons.Default.Link,
                                contentDescription = null,
                                tint = LitterTheme.textMuted,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                            OutlinedTextField(
                                value = videoUrlText,
                                onValueChange = { videoUrlText = it },
                                placeholder = { Text("Paste video URL", fontSize = 12.sp) },
                                singleLine = true,
                                modifier = Modifier
                                    .weight(1f)
                                    .heightIn(max = 44.dp),
                                textStyle = androidx.compose.ui.text.TextStyle(
                                    fontSize = 12.sp,
                                    color = LitterTheme.textPrimary,
                                ),
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = LitterTheme.accent,
                                    unfocusedBorderColor = LitterTheme.border,
                                    cursorColor = LitterTheme.accent,
                                ),
                                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                                keyboardActions = KeyboardActions(onGo = {
                                    val url = videoUrlText.trim()
                                    if (url.isNotEmpty()) {
                                        isProcessingVideo = true
                                        scope.launch {
                                            val result = VideoWallpaperProcessor.processRemoteUrl(
                                                context,
                                                url,
                                                WallpaperScope.Pending,
                                            )
                                            if (result != null) {
                                                val config = WallpaperConfig(
                                                    type = WallpaperType.VIDEO_URL,
                                                    videoURL = url,
                                                    videoDuration = result.durationSeconds,
                                                    blur = blur,
                                                    brightness = brightness,
                                                    motionEnabled = motionEnabled,
                                                )
                                                WallpaperManager.pendingConfig = config
                                                previewConfig = config
                                                isProcessingVideo = false
                                            } else {
                                                isProcessingVideo = false
                                            }
                                        }
                                    }
                                }),
                            )
                        }
                    }
                }
            }
        }

        // Processing overlay
        if (isProcessingVideo) {
            Box(
                modifier = Modifier.fillMaxSize().background(LitterTheme.background.copy(alpha = 0.6f)),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = LitterTheme.accent)
                    Spacer(Modifier.height(12.dp))
                    Text("Processing video...", color = LitterTheme.textPrimary, fontSize = 13.sp)
                }
            }
        }
    }
}

@Composable
private fun ThemeThumbnail(
    label: String,
    backgroundColor: Color,
    accentColor: Color?,
    isSelected: Boolean,
    isNone: Boolean = false,
    onClick: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .width(64.dp)
            .clickable(onClick = onClick),
    ) {
        Box(
            modifier = Modifier
                .size(56.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(backgroundColor)
                .then(
                    if (isSelected) {
                        Modifier.border(2.dp, LitterTheme.accent, RoundedCornerShape(10.dp))
                    } else {
                        Modifier.border(1.dp, LitterTheme.border, RoundedCornerShape(10.dp))
                    }
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (isNone) {
                Icon(
                    Icons.Default.Close,
                    contentDescription = "No wallpaper",
                    tint = LitterTheme.textMuted,
                    modifier = Modifier.size(20.dp),
                )
            } else if (accentColor != null) {
                // Mini pattern preview — draw dots
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(accentColor.copy(alpha = 0.5f)),
                )
            }
        }
        Spacer(Modifier.height(4.dp))
        Text(
            text = label,
            color = if (isSelected) LitterTheme.accent else LitterTheme.textMuted,
            fontSize = 9.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun SampleBubble(text: String, isUser: Boolean) {
    val bgColor = if (isUser) LitterTheme.accent.copy(alpha = 0.15f) else LitterTheme.surface.copy(alpha = 0.85f)
    val alignment = if (isUser) Alignment.End else Alignment.Start

    Box(
        modifier = Modifier.fillMaxWidth(),
        contentAlignment = if (isUser) Alignment.CenterEnd else Alignment.CenterStart,
    ) {
        Text(
            text = text,
            color = LitterTheme.textPrimary,
            fontSize = 13.sp,
            modifier = Modifier
                .background(bgColor, RoundedCornerShape(12.dp))
                .padding(horizontal = 12.dp, vertical = 8.dp),
        )
    }
}
