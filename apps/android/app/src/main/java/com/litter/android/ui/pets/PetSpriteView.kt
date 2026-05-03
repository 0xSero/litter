package com.litter.android.ui.pets

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.CachedPetPackage
import com.litter.android.state.PetAvatarState
import com.litter.android.state.PetOverlayController
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

private const val FrameWidth = 192
private const val FrameHeight = 208
private const val Columns = 8
private const val Rows = 9
private const val AtlasWidth = FrameWidth * Columns
private const val AtlasHeight = FrameHeight * Rows

private data class PetSpriteAtlas(
    val image: ImageBitmap,
    val framesByRow: List<List<Int>>,
) {
    fun framesFor(state: PetAvatarState): List<Int> = framesByRow.getOrElse(state.row) { listOf(0) }
}

private data class PetAnimationProfile(
    val frameDurationsMs: List<Long>,
) {
    fun durationMs(frameIndex: Int): Long =
        frameDurationsMs.getOrElse(frameIndex) { frameDurationsMs.lastOrNull() ?: 120L }
}

private fun animationProfileFor(state: PetAvatarState): PetAnimationProfile = when (state) {
    PetAvatarState.IDLE -> PetAnimationProfile(listOf(1680L, 660L, 660L, 840L, 840L, 1920L))
    PetAvatarState.RUNNING_RIGHT,
    PetAvatarState.RUNNING_LEFT -> PetAnimationProfile(listOf(120L, 120L, 120L, 120L, 120L, 120L, 120L, 220L))
    PetAvatarState.RUNNING -> PetAnimationProfile(listOf(120L, 120L, 120L, 120L, 120L, 220L))
    PetAvatarState.WAITING -> PetAnimationProfile(listOf(150L, 150L, 150L, 150L, 150L, 260L))
    PetAvatarState.REVIEW -> PetAnimationProfile(listOf(150L, 150L, 150L, 150L, 150L, 280L))
    PetAvatarState.FAILED -> PetAnimationProfile(listOf(140L, 140L, 140L, 140L, 140L, 140L, 140L, 240L))
    PetAvatarState.JUMPING -> PetAnimationProfile(listOf(140L, 140L, 140L, 140L, 280L))
    PetAvatarState.WAVING -> PetAnimationProfile(listOf(140L, 140L, 140L, 280L))
}

@Composable
fun PetOverlayView(
    pet: CachedPetPackage,
    state: PetAvatarState,
    message: String?,
    reducedMotion: Boolean,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .offset {
                IntOffset(
                    PetOverlayController.dragOffsetX.roundToInt(),
                    PetOverlayController.dragOffsetY.roundToInt(),
                )
            }
            .size(width = 112.dp, height = 122.dp)
            .pointerInput(pet.id) {
                detectDragGestures(
                    onDragStart = { PetOverlayController.startDrag() },
                    onDragCancel = { PetOverlayController.endDrag() },
                    onDragEnd = { PetOverlayController.endDrag() },
                    onDrag = { change, dragAmount ->
                        change.consume()
                        PetOverlayController.dragBy(dragAmount.x, dragAmount.y)
                    },
                )
            },
    ) {
        PetSpriteView(
            spritesheetBytes = pet.spritesheetBytes,
            state = state,
            reducedMotion = reducedMotion,
        )
        if (message != null) {
            PetSpeechBubble(
                text = message,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .offset(x = 64.dp, y = (-10).dp),
            )
        }
    }
}

@Composable
private fun PetSpeechBubble(
    text: String,
    modifier: Modifier = Modifier,
) {
    Text(
        text = text,
        modifier = modifier
            .widthIn(max = 180.dp)
            .background(
                color = LitterTheme.surface.copy(alpha = 0.94f),
                shape = RoundedCornerShape(8.dp),
            )
            .border(
                width = 1.dp,
                color = LitterTheme.border.copy(alpha = 0.9f),
                shape = RoundedCornerShape(8.dp),
            )
            .padding(horizontal = 8.dp, vertical = 5.dp),
        color = LitterTheme.textPrimary,
        fontFamily = LitterTheme.monoFont,
        fontSize = 11.sp,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
fun PetSpriteView(
    spritesheetBytes: ByteArray,
    state: PetAvatarState,
    reducedMotion: Boolean,
    modifier: Modifier = Modifier,
) {
    var atlas by remember(spritesheetBytes) { mutableStateOf<PetSpriteAtlas?>(null) }
    LaunchedEffect(spritesheetBytes) {
        atlas = withContext(Dispatchers.Default) {
            decodeAtlas(spritesheetBytes)
        }
    }
    var playbackState by remember(state, reducedMotion, atlas) { mutableStateOf(state) }
    val frames = atlas?.framesFor(playbackState) ?: listOf(0)
    var frameIndex by remember(state, reducedMotion, atlas) { mutableIntStateOf(0) }

    LaunchedEffect(state, reducedMotion, atlas) {
        playbackState = state
        frameIndex = 0
        if (reducedMotion) return@LaunchedEffect

        suspend fun playLoop(loopState: PetAvatarState, cycles: Int? = null) {
            val loopFrames = atlas?.framesFor(loopState) ?: listOf(0)
            if (loopFrames.size <= 1) return
            val profile = animationProfileFor(loopState)
            var completedCycles = 0
            while (cycles == null || completedCycles < cycles) {
                loopFrames.indices.forEach { index ->
                    playbackState = loopState
                    frameIndex = index
                    delay(profile.durationMs(index))
                }
                completedCycles += 1
            }
        }

        if (state == PetAvatarState.IDLE) {
            playLoop(PetAvatarState.IDLE)
        } else {
            playLoop(state, cycles = 3)
            playbackState = PetAvatarState.IDLE
            frameIndex = 0
            playLoop(PetAvatarState.IDLE)
        }
    }

    Canvas(
        modifier = modifier.aspectRatio(FrameWidth.toFloat() / FrameHeight.toFloat()),
    ) {
        val bitmap = atlas?.image ?: return@Canvas
        val frame = frames.getOrElse(frameIndex) { frames.firstOrNull() ?: 0 }
        drawImage(
            image = bitmap,
            srcOffset = IntOffset(frame * FrameWidth, playbackState.row * FrameHeight),
            srcSize = IntSize(FrameWidth, FrameHeight),
            dstOffset = IntOffset.Zero,
            dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt()),
            filterQuality = FilterQuality.None,
        )
    }
}

private fun decodeAtlas(bytes: ByteArray): PetSpriteAtlas? =
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        ?.takeIf { it.width == AtlasWidth && it.height == AtlasHeight }
        ?.let { bitmap ->
            PetSpriteAtlas(
                image = bitmap.asImageBitmap(),
                framesByRow = detectNonTransparentFrames(bitmap),
            )
        }

private fun detectNonTransparentFrames(bitmap: Bitmap): List<List<Int>> {
    val framePixels = IntArray(FrameWidth * FrameHeight)
    return List(Rows) { row ->
        (0 until Columns).filter { column ->
            bitmap.getPixels(
                framePixels,
                0,
                FrameWidth,
                column * FrameWidth,
                row * FrameHeight,
                FrameWidth,
                FrameHeight,
            )
            framePixels.any { pixel -> (pixel ushr 24) != 0 }
        }.ifEmpty { listOf(0) }
    }
}
