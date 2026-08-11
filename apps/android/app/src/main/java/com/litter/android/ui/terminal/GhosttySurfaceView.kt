package com.litter.android.ui.terminal

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.text.InputType
import android.view.Choreographer
import android.view.GestureDetector
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowInsets
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.MutableState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color as ComposeColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.litter.android.core.bridge.GhosttyInputCallback
import com.litter.android.core.bridge.GhosttyRendererBridge
import com.litter.android.core.bridge.GhosttyRendererStatus
import com.litter.android.core.bridge.GhosttyWakeupListener
import com.litter.android.state.ActiveTerminalRegistry
import com.litter.android.state.TerminalSessionController
import com.litter.android.ui.LitterTheme
import java.io.ByteArrayOutputStream
import java.io.File
import uniffi.codex_mobile_client.TerminalBellListener
import uniffi.codex_mobile_client.TerminalCellMetrics
import uniffi.codex_mobile_client.TerminalCellPosition
import uniffi.codex_mobile_client.TerminalCellRange
import uniffi.codex_mobile_client.TerminalConfig
import uniffi.codex_mobile_client.TerminalRenderer

/// Composable wrapper around the native Ghostty surface. Owns lifecycle
/// for the SurfaceView + paints a Compose-side selection overlay on top
/// (handles + highlight rectangles).
@Composable
internal fun GhosttyTerminalSurface(
    controller: TerminalSessionController,
    rendererStatus: GhosttyRendererStatus,
    onRendererUnavailable: () -> Unit,
    config: TerminalConfig? = null,
    onFontSizeChanged: ((Float) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val context = LocalContext.current
    val viewRef = remember { GhosttySurfaceHolder() }
    val selectionState = remember { mutableStateOf<TerminalCellRange?>(null) }
    val metricsState = remember { mutableStateOf<TerminalCellMetrics?>(null) }
    val contentScaleState = remember { mutableStateOf(density.density) }

    Box(modifier = modifier) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                GhosttyAndroidSurfaceView(
                    context = ctx,
                    rendererStatus = rendererStatus,
                    scale = density.density,
                    fontSize = with(density) { TerminalConfigPrefs.fontSize.toSp().value },
                    onRendererUnavailable = onRendererUnavailable,
                    inputCallback = GhosttyInputCallback { bytes -> controller.sendBytes(bytes) },
                    onFontSizeChanged = onFontSizeChanged,
                ).also { view ->
                    viewRef.view = view
                    view.onSelectionRangeChanged = { range ->
                        selectionState.value = range
                        metricsState.value = view.cellMetrics()
                    }
                    view.onMetricsChanged = { metrics ->
                        metricsState.value = metrics
                    }
                    contentScaleState.value = density.density
                }
            },
            update = { view ->
                view.scale = density.density
                view.fontSize = with(density) { TerminalConfigPrefs.fontSize.toSp().value }
                view.inputCallback = GhosttyInputCallback { bytes -> controller.sendBytes(bytes) }
                view.onFontSizeChanged = onFontSizeChanged
                viewRef.view = view
                contentScaleState.value = density.density
            },
        )

        // Sibling Compose layer painting the selection highlight + handles
        // on top of the SurfaceView. Touches on handles are forwarded to
        // the surface view (its gesture detector hit-tests them).
        SelectionOverlay(
            range = selectionState.value,
            metrics = metricsState.value,
            contentScale = contentScaleState.value,
        )

        // Floating action menu (Copy / Paste / Select All) anchored at the
        // top of the current selection range. Hidden when no selection.
        SelectionActionMenu(
            range = selectionState.value,
            metrics = metricsState.value,
            contentScale = contentScaleState.value,
            onCopy = {
                val view = viewRef.view ?: return@SelectionActionMenu
                view.copySelectionToClipboard()
            },
            onPaste = {
                viewRef.view?.pasteFromClipboard()
            },
            onSelectAll = {
                viewRef.view?.selectAll()
            },
            onDismiss = {
                viewRef.view?.clearSelection()
            },
        )
    }

    DisposableEffect(controller, viewRef) {
        controller.setOutputByteSink { bytes ->
            viewRef.view?.writeTerminalBytes(bytes)
        }
        onDispose {
            controller.setOutputByteSink(null)
            viewRef.view?.inputCallback = null
            viewRef.view?.onSelectionRangeChanged = null
            viewRef.view?.onMetricsChanged = null
            viewRef.view?.onFontSizeChanged = null
            viewRef.view = null
        }
    }

    LaunchedEffect(config, viewRef) {
        config?.let { viewRef.view?.applyConfig(it) }
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, viewRef) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> viewRef.view?.setOccluded(false)
                Lifecycle.Event.ON_STOP -> viewRef.view?.setOccluded(true)
                Lifecycle.Event.ON_RESUME -> viewRef.view?.setFocused(true)
                Lifecycle.Event.ON_PAUSE -> viewRef.view?.setFocused(false)
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }
}

@Composable
private fun SelectionOverlay(
    range: TerminalCellRange?,
    metrics: TerminalCellMetrics?,
    contentScale: Float,
) {
    if (range == null || metrics == null || metrics.cols == 0u || contentScale <= 0f) return
    val highlight = ComposeColor(0xFF1F6FEB).copy(alpha = 0.30f)
    val handle = ComposeColor(0xFF1F6FEB)
    val normalized = normalizeRange(range)
    val cellW = metrics.cellWidthPx.toFloat() / contentScale
    val cellH = metrics.cellHeightPx.toFloat() / contentScale
    val lastCol = if (metrics.cols == 0u) 0u else metrics.cols - 1u

    Canvas(modifier = Modifier.fillMaxSize()) {
        val cellWPx = cellW * density
        val cellHPx = cellH * density
        // Highlight rectangles.
        val startRow = normalized.start.row.toInt()
        val endRow = normalized.end.row.toInt()
        for (row in startRow..endRow) {
            val firstCol = if (row.toUInt() == normalized.start.row) normalized.start.col else 0u
            val endCol = if (row.toUInt() == normalized.end.row) normalized.end.col else lastCol
            if (endCol < firstCol) continue
            val width = (endCol.toInt() - firstCol.toInt() + 1).toFloat() * cellWPx
            val topInset = (cellHPx * 0.06f).coerceAtLeast(1f)
            drawRect(
                color = highlight,
                topLeft = Offset(firstCol.toInt() * cellWPx, row * cellHPx + topInset),
                size = Size(width, (cellHPx - 2 * topInset).coerceAtLeast(1f)),
            )
        }
        // Handles at start (bottom-left) + end (bottom-right) of the range.
        val handleRadius = 8f * density
        val startCenter = Offset(
            x = normalized.start.col.toFloat() * cellWPx,
            y = (normalized.start.row.toInt() + 1) * cellHPx,
        )
        val endCenter = Offset(
            x = (normalized.end.col.toInt() + 1) * cellWPx,
            y = (normalized.end.row.toInt() + 1) * cellHPx,
        )
        drawCircle(color = handle, radius = handleRadius, center = startCenter)
        drawCircle(color = handle, radius = handleRadius, center = endCenter)
    }
}

@Composable
private fun SelectionActionMenu(
    range: TerminalCellRange?,
    metrics: TerminalCellMetrics?,
    contentScale: Float,
    onCopy: () -> Unit,
    onPaste: () -> Unit,
    onSelectAll: () -> Unit,
    onDismiss: () -> Unit,
) {
    if (range == null || metrics == null || metrics.cols == 0u || contentScale <= 0f) return
    val normalized = normalizeRange(range)
    val density = LocalDensity.current
    val cellWPt = metrics.cellWidthPx.toFloat() / contentScale
    val cellHPt = metrics.cellHeightPx.toFloat() / contentScale
    // Anchor the menu just above the first selection row.
    val xPt = normalized.start.col.toFloat() * cellWPt
    val yPt = normalized.start.row.toInt() * cellHPt

    val xOffsetDp = with(density) { xPt.toDp() }
    val yOffsetDp = with(density) { (yPt - 48f).coerceAtLeast(0f).toDp() }

    Box(
        modifier = Modifier
            .offset(x = xOffsetDp, y = yOffsetDp)
            .clip(RoundedCornerShape(10.dp))
            .background(ComposeColor(0xFF1F1F1F)),
    ) {
        androidx.compose.foundation.layout.Row {
            ActionMenuItem("Copy", onCopy)
            ActionMenuItem("Paste", onPaste)
            ActionMenuItem("All", onSelectAll)
            ActionMenuItem("✕", onDismiss)
        }
    }
}

@Composable
private fun ActionMenuItem(label: String, onClick: () -> Unit) {
    Text(
        text = label,
        color = LitterTheme.textPrimary,
        fontFamily = LitterTheme.monoFont,
        fontSize = 13.sp,
        modifier = Modifier
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    )
}

private fun normalizeRange(range: TerminalCellRange): TerminalCellRange {
    val startBeforeEnd = range.start.row < range.end.row ||
        (range.start.row == range.end.row && range.start.col <= range.end.col)
    return if (startBeforeEnd) {
        range
    } else {
        TerminalCellRange(range.end, range.start, range.rectangle)
    }
}

private class GhosttySurfaceHolder {
    var view: GhosttyAndroidSurfaceView? = null
}

private class GhosttyAndroidSurfaceView(
    context: Context,
    private val rendererStatus: GhosttyRendererStatus,
    var scale: Float,
    var fontSize: Float,
    private val onRendererUnavailable: () -> Unit,
    inputCallback: GhosttyInputCallback?,
    var onFontSizeChanged: ((Float) -> Unit)? = null,
) : SurfaceView(context), SurfaceHolder.Callback {
    private val pendingBytes = ArrayDeque<ByteArray>()
    private val outputLock = Any()
    private val outputBuffer = ByteArrayOutputStream()
    private var rendererSurface: GhosttyRendererBridge.GhosttyRendererSurface? = null
    private var terminalRenderer: TerminalRenderer? = null
    private var backendBridge: GhosttyRendererBackendBridge? = null
    private var bellListenerRef: TerminalBellListener? = null
    private var widthPx: Int = 1
    private var heightPx: Int = 1
    private var frameScheduled = false
    private var rendererUnavailableReported = false
    private var didSetConfigDir = false
    private var pendingConfig: TerminalConfig? = null
    @Volatile
    private var outputFlushScheduled = false

    /// Selection state — mirrors the BackendBridge's stored range so
    /// Compose can observe it directly. Pushed by `setSelectionOverlay`
    /// via the bridge listener.
    @Volatile
    var onSelectionRangeChanged: ((TerminalCellRange?) -> Unit)? = null

    /// Optional metrics-change notification fired whenever resize might
    /// have moved cell sizes (font change, rotation, resize). Used by
    /// the Compose selection overlay so its math stays in lockstep.
    @Volatile
    var onMetricsChanged: ((TerminalCellMetrics?) -> Unit)? = null

    private var lastBellAt: Long = 0L
    private var selectionAnchor: TerminalCellPosition? = null
    private var selectionDragActive: Boolean = false
    private var activeHandle: SelectionHandle? = null
    private var pinchStartFontSize: Float = TerminalConfigPrefs.fontSize

    enum class SelectionHandle { Start, End }

    var inputCallback: GhosttyInputCallback? = inputCallback
        set(value) {
            field = value
            rendererSurface?.setInputCallback(value)
        }

    private val wakeupListener = GhosttyWakeupListener {
        // Ghostty's wakeup runs on its own thread; hop to the view thread
        // and post a single Choreographer frame instead of self-rescheduling.
        post { scheduleFrame() }
    }

    private val frameCallback = Choreographer.FrameCallback {
        frameScheduled = false
        val renderedByTick = rendererSurface?.tick() == true
        if (!renderedByTick) {
            rendererSurface?.draw()
        }
    }

    private val outputFlushRunnable = Runnable {
        flushTerminalBytesOnViewThread()
    }

    private val scaleGestureDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                pinchStartFontSize = TerminalConfigPrefs.fontSize
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val target = (pinchStartFontSize * detector.scaleFactor)
                    .coerceIn(10f, 24f)
                TerminalConfigPrefs.setFontSize(context, target)
                onFontSizeChanged?.invoke(target)
                return true
            }

            override fun onScaleEnd(detector: ScaleGestureDetector) {
                // Notify the host one more time so it can re-run the
                // grid math against the new cell metrics.
                onFontSizeChanged?.invoke(TerminalConfigPrefs.fontSize)
            }
        },
    )

    private val gestureDetector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onScroll(
                e1: MotionEvent?,
                e2: MotionEvent,
                distanceX: Float,
                distanceY: Float,
            ): Boolean {
                if (selectionDragActive) return false
                val twoFinger = e2.pointerCount >= 2
                if (!twoFinger) return false
                rendererSurface?.mouseScroll(
                    x = -distanceX.toDouble(),
                    y = -distanceY.toDouble(),
                    precise = true,
                )
                return true
            }

            override fun onLongPress(e: MotionEvent) {
                val renderer = terminalRenderer ?: return
                val pos = renderer.hitTest(e.x * scale, e.y * scale) ?: return
                val initial = renderer.wordRangeAt(pos)
                    ?: TerminalCellRange(pos, pos, false)
                renderer.selectionSet(initial)
                selectionAnchor = pos
                selectionDragActive = true
                activeHandle = null
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            }

            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                val renderer = terminalRenderer ?: return false
                if (currentSelectionRange() != null) {
                    clearSelection()
                    return true
                }
                renderer.updateViewportLinksFromSurface()
                val link = renderer.linkAtPoint(e.x * scale, e.y * scale)
                if (link != null) {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(link.url))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    runCatching { context.startActivity(intent) }
                    return true
                }
                showIme()
                return true
            }
        },
    )

    init {
        setBackgroundColor(Color.BLACK)
        holder.addCallback(this)
        isFocusable = true
        isFocusableInTouchMode = true
        isLongClickable = true
        isHapticFeedbackEnabled = true
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = (
            InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
        )
        outAttrs.imeOptions = (
            EditorInfo.IME_FLAG_NO_EXTRACT_UI or
                EditorInfo.IME_FLAG_NO_FULLSCREEN or
                EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING or
                EditorInfo.IME_ACTION_NONE
        )
        return GhosttyInputConnection(this)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (sendKeyEventToGhostty(event)) return true
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (sendKeyEventToGhostty(event)) return true
        return super.onKeyUp(keyCode, event)
    }

    internal fun sendKeyEventToGhostty(event: KeyEvent): Boolean {
        val renderer = rendererSurface ?: return false
        val action = when (event.action) {
            KeyEvent.ACTION_DOWN -> if (event.repeatCount > 0) 2 else 1
            KeyEvent.ACTION_UP -> 0
            else -> return false
        }
        val bridgeKey = KeyEventTranslator.bridgeKey(event.keyCode)
        if (bridgeKey == 0 && event.unicodeChar == 0) {
            return false
        }
        val mods = KeyEventTranslator.packMods(event)
        val text = when {
            event.unicodeChar != 0 -> Character.toString(event.unicodeChar.toChar())
            else -> null
        }
        renderer.sendKey(action, bridgeKey, mods, text, composing = false)
        return true
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        // Pinch wins outright while two fingers are down.
        val pinchHandled = scaleGestureDetector.onTouchEvent(event)
        if (scaleGestureDetector.isInProgress) return true

        // Long-press / single-tap / two-finger scroll.
        if (gestureDetector.onTouchEvent(event)) return true

        // Active selection drag — finger movement extends the selection.
        if (selectionDragActive) {
            val renderer = terminalRenderer
            if (renderer != null) {
                val px = event.x * scale
                val py = event.y * scale
                val focus = renderer.hitTest(px, py)
                if (focus != null && selectionAnchor != null) {
                    val anchor = selectionAnchor ?: return false
                    renderer.selectionSet(
                        TerminalCellRange(anchor, focus, false),
                    )
                }
            }
            if (event.actionMasked == MotionEvent.ACTION_UP ||
                event.actionMasked == MotionEvent.ACTION_CANCEL
            ) {
                selectionDragActive = false
                selectionAnchor = null
            }
            return true
        }

        // Mouse-tracking applications (vim, htop) — single-touch drag
        // becomes a mouse drag inside the terminal.
        val renderer = rendererSurface
        if (renderer != null && renderer.mouseCaptured()) {
            val px = event.x.toDouble()
            val py = event.y.toDouble()
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    renderer.mouseMove(px, py)
                    renderer.mouseButton(pressed = true, button = 1)
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    renderer.mouseMove(px, py)
                    return true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    renderer.mouseButton(pressed = false, button = 1)
                    return true
                }
            }
        }
        return pinchHandled || super.onTouchEvent(event)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        createRendererSurface(holder)
    }

    override fun surfaceChanged(
        holder: SurfaceHolder,
        format: Int,
        width: Int,
        height: Int,
    ) {
        widthPx = width.coerceAtLeast(1)
        heightPx = height.coerceAtLeast(1)
        rendererSurface?.resize(widthPx, heightPx, scale) ?: createRendererSurface(holder)
        scheduleFrame()
        onMetricsChanged?.invoke(cellMetrics())
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        stopFrameLoop()
        removeCallbacks(outputFlushRunnable)
        synchronized(outputLock) {
            outputBuffer.reset()
            outputFlushScheduled = false
        }
        terminalRenderer?.let { ActiveTerminalRegistry.unregister(it) }
        terminalRenderer?.detach()
        terminalRenderer?.close()
        terminalRenderer = null
        backendBridge = null
        bellListenerRef = null
        rendererSurface?.close()
        rendererSurface = null
        didSetConfigDir = false
    }

    fun writeTerminalBytes(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        var shouldSchedule = false
        synchronized(outputLock) {
            outputBuffer.write(bytes)
            if (!outputFlushScheduled) {
                outputFlushScheduled = true
                shouldSchedule = true
            }
        }
        if (shouldSchedule) {
            postDelayed(outputFlushRunnable, 8L)
        }
    }

    private fun flushTerminalBytesOnViewThread() {
        val bytes = synchronized(outputLock) {
            val data = outputBuffer.toByteArray()
            outputBuffer.reset()
            outputFlushScheduled = false
            data
        }
        if (bytes.isEmpty()) return

        val activeRenderer = rendererSurface
        if (activeRenderer != null) {
            // Tee bytes through the Rust OSC parser + bell detector before
            // writing to Ghostty, so bell events fire and OSC8 cwd updates.
            terminalRenderer?.feedOutput(bytes)
            activeRenderer.write(bytes)
            return
        }

        if (pendingBytes.size >= 128) {
            pendingBytes.removeFirst()
        }
        pendingBytes.addLast(bytes)
    }

    private fun createRendererSurface(holder: SurfaceHolder) {
        if (!rendererStatus.canCreateAndroidSurface || rendererSurface != null) {
            return
        }

        val createdRenderer = GhosttyRendererBridge.createSurface(
            surface = holder.surface,
            width = widthPx,
            height = heightPx,
            scale = scale,
            fontSize = fontSize,
        )
        if (createdRenderer == null) {
            reportRendererUnavailable()
            return
        }
        rendererSurface = createdRenderer
        createdRenderer.setInputCallback(inputCallback)
        createdRenderer.setWakeupListener(wakeupListener)

        val bridge = GhosttyRendererBackendBridge(
            surface = createdRenderer,
            onRequestRedraw = { scheduleFrame() },
            onPasteBytes = { bytes -> inputCallback?.onInput(bytes) },
        )
        bridge.onSelectionRangeChanged = { range ->
            onSelectionRangeChanged?.invoke(range)
        }
        backendBridge = bridge
        val renderer = TerminalRenderer(backend = bridge)
        terminalRenderer = renderer
        ActiveTerminalRegistry.register(renderer)
        val bellListener = object : TerminalBellListener {
            override fun onBell() {
                post { fireBellHaptic() }
            }
        }
        renderer.subscribeBell(bellListener)
        bellListenerRef = bellListener

        while (pendingBytes.isNotEmpty()) {
            val bytes = pendingBytes.removeFirst()
            renderer.feedOutput(bytes)
            createdRenderer.write(bytes)
        }
        pendingConfig?.let { config ->
            pendingConfig = null
            applyConfig(config)
        }
        // Paint the first frame; subsequent frames are scheduled on demand
        // via `wakeupListener` or `setOccluded(false)`.
        scheduleFrame()
        onMetricsChanged?.invoke(cellMetrics())
    }

    fun setOccluded(occluded: Boolean) {
        terminalRenderer?.setOccluded(occluded) ?: rendererSurface?.setOcclusion(occluded)
    }

    fun setFocused(focused: Boolean) {
        terminalRenderer?.setFocused(focused) ?: rendererSurface?.setFocus(focused)
    }

    fun applyConfig(config: TerminalConfig) {
        val renderer = terminalRenderer
        if (renderer == null) {
            // Surface not created yet — replay once the renderer is attached.
            pendingConfig = config
            return
        }
        ensureConfigDir(renderer)
        try {
            renderer.applyConfig(config)
            rendererSurface?.resize(widthPx, heightPx, scale)
            scheduleFrame()
        } catch (_: Exception) {
            // Renderer was detached between the null-check and the call.
        }
        // Cell sizes likely changed; let the Compose overlay re-sync.
        onMetricsChanged?.invoke(cellMetrics())
    }

    fun cellMetrics(): TerminalCellMetrics? = terminalRenderer?.cellMetrics()

    fun currentSelectionRange(): TerminalCellRange? = backendBridge?.currentSelectionRange()

    fun clearSelection() {
        terminalRenderer?.selectionClear()
    }

    fun selectAll() {
        terminalRenderer?.selectionAll()
    }

    fun copySelectionToClipboard() {
        val renderer = terminalRenderer ?: return
        val text = renderer.readSelection().orEmpty()
        if (text.isNotEmpty()) {
            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE)
                as android.content.ClipboardManager
            clipboard.setPrimaryClip(
                android.content.ClipData.newPlainText("Terminal", text),
            )
        }
        renderer.selectionClear()
    }

    fun pasteFromClipboard() {
        val renderer = terminalRenderer ?: return
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE)
            as android.content.ClipboardManager
        val text = clipboard.primaryClip
            ?.getItemAt(0)
            ?.coerceToText(context)
            ?.toString()
            .orEmpty()
        renderer.selectionClear()
        if (text.isNotEmpty()) renderer.sendPaste(text)
    }

    private fun ensureConfigDir(renderer: TerminalRenderer) {
        if (didSetConfigDir) return
        val dir = File(context.cacheDir, "litter/terminal")
        renderer.setConfigDir(dir.absolutePath)
        didSetConfigDir = true
    }

    internal fun exposedRendererSurface(): GhosttyRendererBridge.GhosttyRendererSurface? =
        rendererSurface

    private fun scheduleFrame() {
        if (frameScheduled || rendererSurface == null) return
        frameScheduled = true
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    private fun stopFrameLoop() {
        if (!frameScheduled) return
        frameScheduled = false
        Choreographer.getInstance().removeFrameCallback(frameCallback)
    }

    private fun reportRendererUnavailable() {
        if (rendererUnavailableReported) return
        rendererUnavailableReported = true
        onRendererUnavailable()
    }

    private fun fireBellHaptic() {
        val now = SystemClock.uptimeMillis()
        if (now - lastBellAt < 250L) return
        lastBellAt = now
        performHapticFeedback(
            HapticFeedbackConstants.LONG_PRESS,
            HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING,
        )
        // System audio bell tied to the call volume — same behaviour
        // shells expect when running on a terminal emulator.
        runCatching {
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            audio?.playSoundEffect(AudioManager.FX_KEYPRESS_STANDARD)
        }
    }

    private fun showIme() {
        requestFocus()
        post {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                windowInsetsController?.show(WindowInsets.Type.ime())
            }
            showImeWithInputMethodManager()
        }
    }

    private fun showImeWithInputMethodManager() {
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
            ?: return
        imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
    }
}

/// Helper extension that snapshots the current viewport text and feeds
/// it to the Rust renderer's URL detector. Called once just before a
/// single-tap dispatches so OSC8 + plain-text URL detection is fresh.
private fun TerminalRenderer.updateViewportLinksFromSurface() {
    // The Rust renderer is fed PTY bytes via `feedOutput` so OSC8 anchors
    // accumulate as the shell emits them. The plain-text URL detector
    // needs an explicit viewport snapshot — but we don't have one
    // immediately available from the Android JNI surface here (the
    // helper exists for iOS where the bridge exposes `visibleText`).
    //
    // Skipping this on Android is fine for OSC8 hyperlinks (the parser
    // already tracked them); plain-text URL detection lights up once the
    // bridge wires a `read_text(viewport)` helper at the Kotlin layer.
}

/**
 * `BaseInputConnection` shim that funnels IME commits, composing-text updates,
 * and synthesized backspaces into the Ghostty renderer. Real hardware key
 * events still flow through [GhosttyAndroidSurfaceView.onKeyDown].
 */
private class GhosttyInputConnection(
    private val view: GhosttyAndroidSurfaceView,
) : BaseInputConnection(view, /* fullEditor = */ false) {

    private fun renderer() = view.exposedRendererSurface()

    override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
        val payload = text?.toString().orEmpty()
        if (payload.isNotEmpty()) {
            renderer()?.sendText(payload)
        }
        return true
    }

    override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
        renderer()?.sendPreedit(text?.toString().takeIf { !it.isNullOrEmpty() })
        return true
    }

    override fun finishComposingText(): Boolean {
        renderer()?.sendPreedit(null)
        return true
    }

    override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
        // We don't track an editable buffer; translate to backspaces.
        val renderer = renderer() ?: return true
        repeat(beforeLength.coerceAtLeast(0)) {
            renderer.sendKey(
                action = 1,
                key = 3, // LitterBridgeKey::Backspace
                mods = 0,
                text = null,
                composing = false,
            )
        }
        return true
    }

    override fun sendKeyEvent(event: KeyEvent?): Boolean {
        val real = event ?: return false
        return view.sendKeyEventToGhostty(real)
    }
}

private object KeyEventTranslator {
    fun packMods(event: KeyEvent): Int {
        var bits = 0
        if (event.isShiftPressed) bits = bits or (1 shl 0)
        if (event.isCtrlPressed) bits = bits or (1 shl 1)
        if (event.isAltPressed) bits = bits or (1 shl 2)
        if (event.isMetaPressed) bits = bits or (1 shl 3)
        return bits
    }

    /**
     * Map Android [KeyEvent] codes to the `LitterBridgeKey` enum the JNI
     * bridge expects (1=Enter, 2=Tab, …). Returns 0 (Unidentified) for
     * codes we want to forward as Unicode text instead.
     */
    fun bridgeKey(keyCode: Int): Int = when (keyCode) {
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> 1
        KeyEvent.KEYCODE_TAB -> 2
        KeyEvent.KEYCODE_DEL -> 3
        KeyEvent.KEYCODE_ESCAPE -> 4
        KeyEvent.KEYCODE_SPACE -> 5
        KeyEvent.KEYCODE_DPAD_UP -> 6
        KeyEvent.KEYCODE_DPAD_DOWN -> 7
        KeyEvent.KEYCODE_DPAD_LEFT -> 8
        KeyEvent.KEYCODE_DPAD_RIGHT -> 9
        KeyEvent.KEYCODE_PAGE_UP -> 10
        KeyEvent.KEYCODE_PAGE_DOWN -> 11
        KeyEvent.KEYCODE_MOVE_HOME -> 12
        KeyEvent.KEYCODE_MOVE_END -> 13
        KeyEvent.KEYCODE_FORWARD_DEL -> 14
        KeyEvent.KEYCODE_INSERT -> 15
        else -> 0
    }
}
