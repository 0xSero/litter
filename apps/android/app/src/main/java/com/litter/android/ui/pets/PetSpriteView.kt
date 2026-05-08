package com.litter.android.ui.pets

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.ViewConfiguration
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.pointerInteropFilter
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
private val PetBodyWidth = 112.dp
private val PetBodyHeight = 122.dp
private val BubbleHostWidth = 140.dp
private val PetTopInset = 52.dp
private val BubbleOffsetY = 0.dp
private val BubbleMaxWidth = 140.dp
private val PetHostWidth = BubbleHostWidth
private val PetHostHeight = PetTopInset + PetBodyHeight
private val AmbientMessages = listOf("Ready", "Watching", "Let's go")
private val AmbientStates = listOf(PetAvatarState.WAVING, PetAvatarState.JUMPING)

data class PetDisplayPresentation(
    val state: PetAvatarState,
    val message: String?,
)

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
    val context = LocalContext.current
    PetAvatarBubble(
        pet = pet,
        state = state,
        message = message,
        reducedMotion = reducedMotion,
        modifier = modifier.offset {
            IntOffset(
                PetOverlayController.dragOffsetX.roundToInt(),
                PetOverlayController.dragOffsetY.roundToInt(),
            )
        },
        onDragStart = { PetOverlayController.startDrag() },
        onDragCancel = { PetOverlayController.endDrag() },
        onDragEnd = { PetOverlayController.endDrag() },
        onDrag = { dx, dy -> PetOverlayController.dragBy(context, dx, dy) },
        onClick = null,
        onLongClick = null,
    )
}

@Composable
private fun rememberPetDisplayPresentation(
    pet: CachedPetPackage,
    state: PetAvatarState,
    message: String?,
    reducedMotion: Boolean,
) : PetDisplayPresentation {
    var ambientState by remember(pet.id, state, message, reducedMotion) { mutableStateOf<PetAvatarState?>(null) }
    var ambientMessage by remember(pet.id, state, message, reducedMotion) { mutableStateOf<String?>(null) }

    LaunchedEffect(pet.id, state, message, reducedMotion) {
        ambientState = null
        ambientMessage = null
        if (state != PetAvatarState.IDLE || message != null) return@LaunchedEffect

        var messageIndex = 0
        var stateIndex = 0
        while (true) {
            delay(3200L)
            if (reducedMotion) {
                ambientState = null
                ambientMessage = AmbientMessages[messageIndex % AmbientMessages.size]
                messageIndex += 1
                delay(2200L)
                ambientMessage = null
                delay(2800L)
                continue
            }

            val nextState = AmbientStates[stateIndex % AmbientStates.size]
            val nextMessage = AmbientMessages[messageIndex % AmbientMessages.size]
            stateIndex += 1
            messageIndex += 1

            ambientState = nextState
            ambientMessage = nextMessage
            delay(
                when (nextState) {
                    PetAvatarState.WAVING -> 1800L
                    PetAvatarState.JUMPING -> 1600L
                    else -> 1400L
                },
            )
            ambientState = null
            ambientMessage = null
            delay(2600L)
        }
    }

    return PetDisplayPresentation(
        state = ambientState ?: state,
        message = message ?: ambientMessage,
    )
}

@Composable
fun PetOverlayBody(
    pet: CachedPetPackage,
    state: PetAvatarState,
    message: String?,
    reducedMotion: Boolean,
    modifier: Modifier = Modifier,
) {
    val presentation = rememberPetDisplayPresentation(
        pet = pet,
        state = state,
        message = message,
        reducedMotion = reducedMotion,
    )
    val scale = PetOverlayController.petScale
    Box(
        modifier = modifier.size(width = PetBodyWidth * scale, height = PetBodyHeight * scale),
    ) {
        PetSpriteView(
            spritesheetBytes = pet.spritesheetBytes,
            state = presentation.state,
            reducedMotion = reducedMotion,
        )
    }
}

@Composable
fun PetOverlayBubbleLabel(
    text: String,
    modifier: Modifier = Modifier,
) {
    PetSpeechBubble(text = text, modifier = modifier)
}

@Composable
@OptIn(ExperimentalComposeUiApi::class)
fun PetAvatarBubble(
    pet: CachedPetPackage,
    state: PetAvatarState,
    message: String?,
    reducedMotion: Boolean,
    modifier: Modifier = Modifier,
    onDragStart: (() -> Unit)? = null,
    onDragCancel: (() -> Unit)? = null,
    onDragEnd: (() -> Unit)? = null,
    onDrag: ((Float, Float) -> Unit)? = null,
    onDragAbsolute: ((Float, Float) -> Unit)? = null,
    onPinchStart: (() -> Unit)? = null,
    onPinch: ((Float) -> Unit)? = null,
    onPinchEnd: (() -> Unit)? = null,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val touchSlop = remember(context) { ViewConfiguration.get(context).scaledTouchSlop.toFloat() }
    val longPressTimeoutMs = remember { ViewConfiguration.getLongPressTimeout().toLong() }
    val longPressHandler = remember { Handler(Looper.getMainLooper()) }
    var activePointerId by remember(pet.id) { mutableIntStateOf(MotionEvent.INVALID_POINTER_ID) }
    var downRawX by remember(pet.id) { mutableStateOf(0f) }
    var downRawY by remember(pet.id) { mutableStateOf(0f) }
    var lastRawX by remember(pet.id) { mutableStateOf(0f) }
    var lastRawY by remember(pet.id) { mutableStateOf(0f) }
    var dragStarted by remember(pet.id) { mutableStateOf(false) }
    var longPressTriggered by remember(pet.id) { mutableStateOf(false) }
    var pinching by remember(pet.id) { mutableStateOf(false) }
    var pinchOccurred by remember(pet.id) { mutableStateOf(false) }
    var pinchInitialDistance by remember(pet.id) { mutableStateOf(0f) }
    val longPressRunnable = remember(pet.id, onLongClick) {
        Runnable {
            if (!dragStarted && !pinching) {
                longPressTriggered = true
                onLongClick?.invoke()
            }
        }
    }
    val presentation = rememberPetDisplayPresentation(
        pet = pet,
        state = state,
        message = message,
        reducedMotion = reducedMotion,
    )
    val displayState = presentation.state
    val displayMessage = presentation.message

    val scale = PetOverlayController.petScale
    val bodyWidth = PetBodyWidth * scale
    val bodyHeight = PetBodyHeight * scale
    val hostWidth = bodyWidth.coerceAtLeast(BubbleHostWidth)
    val hostHeight = PetTopInset + bodyHeight

    Box(
        modifier = modifier
            .size(width = hostWidth, height = hostHeight)
            .pointerInteropFilter { event ->
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        activePointerId = event.getPointerId(0)
                        downRawX = event.rawX
                        downRawY = event.rawY
                        lastRawX = event.rawX
                        lastRawY = event.rawY
                        dragStarted = false
                        longPressTriggered = false
                        pinching = false
                        pinchOccurred = false
                        longPressHandler.removeCallbacks(longPressRunnable)
                        longPressHandler.postDelayed(longPressRunnable, longPressTimeoutMs)
                        true
                    }

                    MotionEvent.ACTION_POINTER_DOWN -> {
                        if (event.pointerCount == 2) {
                            longPressHandler.removeCallbacks(longPressRunnable)
                            if (dragStarted) {
                                onDragEnd?.invoke()
                                dragStarted = false
                            }
                            val initial = pointerSpan(event)
                            if (initial > 0f) {
                                pinchInitialDistance = initial
                                pinching = true
                                pinchOccurred = true
                                onPinchStart?.invoke()
                            }
                        }
                        true
                    }

                    MotionEvent.ACTION_MOVE -> {
                        if (pinching) {
                            if (event.pointerCount >= 2) {
                                val current = pointerSpan(event)
                                if (pinchInitialDistance > 0f && current > 0f) {
                                    onPinch?.invoke(current / pinchInitialDistance)
                                }
                            }
                            return@pointerInteropFilter true
                        }
                        if (activePointerId == MotionEvent.INVALID_POINTER_ID) return@pointerInteropFilter false
                        val pointerIndex = event.findPointerIndex(activePointerId)
                        if (pointerIndex < 0) return@pointerInteropFilter false

                        val rawX = event.rawX
                        val rawY = event.rawY
                        val totalDx = rawX - downRawX
                        val totalDy = rawY - downRawY

                        if (!dragStarted && !longPressTriggered) {
                            val distance = kotlin.math.hypot(totalDx.toDouble(), totalDy.toDouble()).toFloat()
                            if (distance > touchSlop) {
                                dragStarted = true
                                longPressHandler.removeCallbacks(longPressRunnable)
                                onDragStart?.invoke()
                            }
                        }

                        if (dragStarted) {
                            val dx = rawX - lastRawX
                            val dy = rawY - lastRawY
                            if (onDragAbsolute != null) {
                                onDragAbsolute.invoke(totalDx, totalDy)
                            } else if (dx != 0f || dy != 0f) {
                                onDrag?.invoke(dx, dy)
                            }
                        }

                        lastRawX = rawX
                        lastRawY = rawY
                        true
                    }

                    MotionEvent.ACTION_POINTER_UP -> {
                        if (pinching) {
                            pinching = false
                            onPinchEnd?.invoke()
                            activePointerId = MotionEvent.INVALID_POINTER_ID
                        }
                        true
                    }

                    MotionEvent.ACTION_UP -> {
                        longPressHandler.removeCallbacks(longPressRunnable)
                        if (pinching) {
                            pinching = false
                            onPinchEnd?.invoke()
                        } else if (dragStarted) {
                            onDragEnd?.invoke()
                        } else if (!longPressTriggered && !pinchOccurred) {
                            onClick?.invoke()
                        }
                        activePointerId = MotionEvent.INVALID_POINTER_ID
                        dragStarted = false
                        longPressTriggered = false
                        pinchOccurred = false
                        true
                    }

                    MotionEvent.ACTION_CANCEL -> {
                        longPressHandler.removeCallbacks(longPressRunnable)
                        if (pinching) {
                            pinching = false
                            onPinchEnd?.invoke()
                        } else if (dragStarted) {
                            onDragCancel?.invoke()
                        }
                        activePointerId = MotionEvent.INVALID_POINTER_ID
                        dragStarted = false
                        longPressTriggered = false
                        pinchOccurred = false
                        true
                    }

                    else -> false
                }
            },
    ) {
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .size(width = bodyWidth, height = bodyHeight),
        ) {
            PetSpriteView(
                spritesheetBytes = pet.spritesheetBytes,
                state = displayState,
                reducedMotion = reducedMotion,
            )
        }
        if (displayMessage != null) {
            PetSpeechBubble(
                text = displayMessage,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .offset(y = BubbleOffsetY),
            )
        }
    }
}

private fun pointerSpan(event: MotionEvent): Float {
    if (event.pointerCount < 2) return 0f
    val dx = event.getX(0) - event.getX(1)
    val dy = event.getY(0) - event.getY(1)
    return kotlin.math.hypot(dx.toDouble(), dy.toDouble()).toFloat()
}

@Composable
private fun PetSpeechBubble(
    text: String,
    modifier: Modifier = Modifier,
) {
    Text(
        text = text,
        modifier = modifier
            .widthIn(max = BubbleMaxWidth)
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
