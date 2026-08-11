package com.litter.android.ui.apps

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.litter.android.state.SavedAppsStore
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.conversation.AppStateInjection
import com.litter.android.ui.conversation.WidgetBridge
import com.litter.android.ui.conversation.escapeJsString
import com.litter.android.ui.conversation.pushWidgetContent
import com.litter.android.ui.conversation.wrapWidgetHtml
import com.litter.android.ui.scaled
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.SavedApp
import uniffi.codex_mobile_client.SavedAppWithPayload

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun SavedAppScreen(
    appId: String,
    onBack: () -> Unit,
    onOpenConversation: ((uniffi.codex_mobile_client.ThreadKey) -> Unit)? = null,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val appModel = LocalAppModel.current

    var payload by remember(appId) { mutableStateOf<SavedAppWithPayload?>(null) }
    var loadState by remember(appId) { mutableStateOf<LoadState>(LoadState.Loading) }
    var showMenu by remember { mutableStateOf(false) }
    var renameDialogVisible by remember { mutableStateOf(false) }
    var deleteConfirmVisible by remember { mutableStateOf(false) }
    var showUpdateOverlay by remember { mutableStateOf(false) }
    var isUpdating by remember { mutableStateOf(false) }
    var reloadTick by remember { mutableStateOf(0) }

    LaunchedEffect(appId, reloadTick) {
        loadState = LoadState.Loading
        try {
            val fetched = SavedAppsStore.getWithPayload(context, appId)
            if (fetched == null) {
                loadState = LoadState.Broken
            } else {
                payload = fetched
                loadState = LoadState.Ready
            }
        } catch (e: Exception) {
            loadState = LoadState.Failed(e.message ?: "Couldn't load app.")
        }
    }

    DisposableEffect(appId) {
        onDispose {
            scope.launch { SavedAppsStore.flushPendingSave(context, appId) }
        }
    }

    val currentPayload = payload
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(LitterTheme.background)
            .systemBarsPadding(),
    ) {
        val originThreadKey = currentPayload?.app?.let { app ->
            resolveOriginThreadKey(appModel, app)
        }
        TopBar(
            title = currentPayload?.app?.title.orEmpty(),
            onBack = onBack,
            onTitleClick = { renameDialogVisible = true },
            onUpdate = { showUpdateOverlay = true },
            onOpenMenu = { showMenu = true },
            onViewConversation = if (originThreadKey != null && onOpenConversation != null) {
                { onOpenConversation(originThreadKey) }
            } else null,
            isUpdating = isUpdating,
        )
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            DropdownMenuItem(
                text = { Text("Rename") },
                onClick = {
                    showMenu = false
                    renameDialogVisible = true
                },
            )
            DropdownMenuItem(
                text = { Text("Delete", color = LitterTheme.danger) },
                onClick = {
                    showMenu = false
                    deleteConfirmVisible = true
                },
            )
        }

        Box(modifier = Modifier.fillMaxSize()) {
            when (val state = loadState) {
                LoadState.Loading -> LoadingPlaceholder()
                LoadState.Broken -> BrokenPlaceholder(
                    onDelete = {
                        scope.launch {
                            try {
                                SavedAppsStore.delete(context, appId)
                            } catch (_: Exception) {}
                            onBack()
                        }
                    },
                )
                is LoadState.Failed -> FailurePlaceholder(state.message) {
                    reloadTick += 1
                }
                LoadState.Ready -> {
                    if (currentPayload != null) {
                        AppModeWebView(
                            payload = currentPayload,
                            dimmed = isUpdating,
                            appModel = appModel,
                        )
                    }
                }
            }

            if (isUpdating) {
                ShimmerOverlay()
            }

            if (showUpdateOverlay && currentPayload != null) {
                SavedAppUpdateOverlay(
                    currentTitle = currentPayload.app.title,
                    onDismiss = {
                        if (!isUpdating) showUpdateOverlay = false
                    },
                    onSubmit = { prompt ->
                        isUpdating = true
                        scope.launch {
                            val serverId = resolveServerId(appModel, currentPayload.app)
                            try {
                                if (serverId == null) {
                                    throw IllegalStateException(
                                        "No connected server. Connect one and try again.",
                                    )
                                }
                                SavedAppsStore.requestUpdate(
                                    context = context,
                                    serverId = serverId,
                                    appId = appId,
                                    prompt = prompt,
                                )
                                showUpdateOverlay = false
                                reloadTick += 1
                                android.widget.Toast.makeText(
                                    context,
                                    "App updated",
                                    android.widget.Toast.LENGTH_SHORT,
                                ).show()
                            } catch (e: Exception) {
                                android.widget.Toast.makeText(
                                    context,
                                    "Update failed: ${e.message ?: "unknown error"}",
                                    android.widget.Toast.LENGTH_LONG,
                                ).show()
                            } finally {
                                isUpdating = false
                            }
                        }
                    },
                    isSubmitting = isUpdating,
                )
            }
        }
    }

    if (renameDialogVisible && currentPayload != null) {
        RenameAppDialog(
            currentTitle = currentPayload.app.title,
            onDismiss = { renameDialogVisible = false },
            onRename = { newTitle ->
                renameDialogVisible = false
                scope.launch {
                    try {
                        SavedAppsStore.rename(context, appId, newTitle)
                        reloadTick += 1
                    } catch (_: Exception) {}
                }
            },
        )
    }

    if (deleteConfirmVisible) {
        AlertDialog(
            onDismissRequest = { deleteConfirmVisible = false },
            title = { Text("Delete this app?") },
            text = {
                Text("Its HTML and saved state will be removed from this device.")
            },
            confirmButton = {
                TextButton(onClick = {
                    deleteConfirmVisible = false
                    scope.launch {
                        try {
                            SavedAppsStore.delete(context, appId)
                        } catch (_: Exception) {}
                        onBack()
                    }
                }) { Text("Delete", color = LitterTheme.danger) }
            },
            dismissButton = {
                TextButton(onClick = { deleteConfirmVisible = false }) { Text("Cancel") }
            },
        )
    }
}

private sealed interface LoadState {
    data object Loading : LoadState
    data object Broken : LoadState
    data object Ready : LoadState
    data class Failed(val message: String) : LoadState
}

private fun resolveStructuredResponse(
    webView: WebView?,
    requestId: String,
    responseJson: String,
) {
    if (webView == null) return
    val script = "window.__resolveStructuredResponse(" +
        jsStringLiteral(requestId) +
        "," + jsStringLiteral(responseJson) + ");"
    webView.post { webView.evaluateJavascript(script, null) }
}

private fun rejectStructuredResponse(
    webView: WebView?,
    requestId: String,
    message: String,
) {
    if (webView == null) return
    val script = "window.__rejectStructuredResponse(" +
        jsStringLiteral(requestId) +
        "," + jsStringLiteral(message) + ");"
    webView.post { webView.evaluateJavascript(script, null) }
}

/** JS single-quoted string literal for safe splicing into `evaluateJavascript`. */
private fun jsStringLiteral(s: String): String {
    val sb = StringBuilder(s.length + 2)
    sb.append('\'')
    for (c in s) {
        when (c.code) {
            0x5C -> sb.append("\\\\")
            0x27 -> sb.append("\\'")
            0x0A -> sb.append("\\n")
            0x0D -> sb.append("\\r")
            0x2028 -> sb.append("\\u2028")
            0x2029 -> sb.append("\\u2029")
            else -> sb.append(c)
        }
    }
    sb.append('\'')
    return sb.toString()
}

private fun resolveServerId(
    appModel: com.litter.android.state.AppModel,
    app: SavedApp,
): String? {
    val snapshot = appModel.snapshot.value ?: return null
    val servers = snapshot.servers
    val origin = app.originThreadId?.let { threadId ->
        snapshot.sessionSummaries.firstOrNull { it.key.threadId == threadId }?.key?.serverId
    }
    if (origin != null && servers.any { it.serverId == origin }) return origin
    return snapshot.activeThread?.serverId
        ?: servers.firstOrNull { it.isLocal }?.serverId
        ?: servers.firstOrNull()?.serverId
}

/**
 * Resolve the origin thread key from a saved app, if the thread still exists
 * on a known server. Returns null when the thread has been deleted or the
 * app never recorded an origin.
 */
private fun resolveOriginThreadKey(
    appModel: com.litter.android.state.AppModel,
    app: SavedApp,
): uniffi.codex_mobile_client.ThreadKey? {
    val threadId = app.originThreadId ?: return null
    val snapshot = appModel.snapshot.value ?: return null
    return snapshot.sessionSummaries.firstOrNull { it.key.threadId == threadId }?.key
}

@Composable
private fun TopBar(
    title: String,
    onBack: () -> Unit,
    onTitleClick: () -> Unit,
    onUpdate: () -> Unit,
    onOpenMenu: () -> Unit,
    onViewConversation: (() -> Unit)?,
    isUpdating: Boolean = false,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = LitterTheme.textPrimary,
            )
        }
        Text(
            text = title.ifBlank { "App" },
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.headline.scaled,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier
                .weight(1f)
                .clickable(onClick = onTitleClick)
                .padding(horizontal = 4.dp),
        )
        if (onViewConversation != null) {
            IconButton(onClick = onViewConversation) {
                Icon(
                    Icons.AutoMirrored.Filled.Chat,
                    contentDescription = "View Conversation",
                    tint = LitterTheme.textSecondary,
                )
            }
        }
        Row(
            modifier = Modifier
                .padding(end = 4.dp)
                .clip(RoundedCornerShape(999.dp))
                .border(
                    width = 0.8.dp,
                    color = LitterTheme.accent.copy(alpha = 0.45f),
                    shape = RoundedCornerShape(999.dp),
                )
                .then(
                    if (isUpdating) Modifier else Modifier.clickable(onClick = onUpdate),
                )
                .alpha(if (isUpdating) 0.6f else 1f)
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Refresh,
                contentDescription = null,
                tint = LitterTheme.accent,
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = "Update",
                color = LitterTheme.accent,
                fontSize = LitterTextStyle.footnote.scaled,
                fontWeight = FontWeight.SemiBold,
            )
        }
        IconButton(onClick = onOpenMenu) {
            Icon(
                Icons.Default.MoreVert,
                contentDescription = "More",
                tint = LitterTheme.textSecondary,
            )
        }
    }
}

// Both registered bridge classes annotate every method exposed to JavaScript;
// lint loses those annotations when the remembered Kotlin objects cross into WebView.
@SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
@Composable
private fun AppModeWebView(
    payload: SavedAppWithPayload,
    dimmed: Boolean,
    appModel: com.litter.android.state.AppModel,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val app = payload.app
    val appId = app.id

    // Per-view-session cache of the Rust-owned ephemeral `structuredResponse`
    // thread id. remember(appId) resets it whenever the user navigates to a
    // different saved app or leaves and re-enters the view. Deliberately NOT
    // rememberSaveable — ephemeral thread ids must not survive process death.
    val cachedStructuredThreadId = remember(appId) { mutableStateOf<String?>(null) }
    val webViewRef = remember(appId) { mutableStateOf<WebView?>(null) }

    val savedBridge = remember(appId) {
        SavedAppBridge(
            context = context,
            appId = appId,
            onStructuredRequest = { requestId, prompt, schemaJson ->
                val serverId = resolveServerId(appModel, app)
                if (serverId == null) {
                    rejectStructuredResponse(
                        webViewRef.value,
                        requestId,
                        "No connected server available",
                    )
                    return@SavedAppBridge
                }
                scope.launch {
                    val cached = cachedStructuredThreadId.value
                    val result = try {
                        appModel.client.structuredResponse(
                            serverId = serverId,
                            cachedThreadId = cached,
                            prompt = prompt,
                            outputSchemaJson = schemaJson,
                        )
                    } catch (e: Throwable) {
                        rejectStructuredResponse(
                            webViewRef.value,
                            requestId,
                            e.message ?: "structuredResponse failed",
                        )
                        return@launch
                    }
                    when (result) {
                        is uniffi.codex_mobile_client.StructuredResponseResult.Success -> {
                            cachedStructuredThreadId.value = result.threadId
                            resolveStructuredResponse(
                                webViewRef.value,
                                requestId,
                                result.responseJson,
                            )
                        }
                        is uniffi.codex_mobile_client.StructuredResponseResult.Error -> {
                            rejectStructuredResponse(
                                webViewRef.value,
                                requestId,
                                result.message,
                            )
                        }
                    }
                }
            },
        )
    }
    val widgetBridge = remember(appId) {
        WidgetBridge(
            onHeight = { /* saved-app fills its Composable; no dynamic height needed. */ },
            onSendPrompt = { /* Saved apps don't plumb a composer here. */ },
            onOpenLink = { url ->
                try {
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(url)),
                    )
                } catch (_: Exception) {}
            },
            onReady = { /* Informational. */ },
        )
    }

    // Shell is static for a given payload; only the body HTML changes if the
    // app is updated via the overlay. Build shell once (empty body) and push
    // the widget HTML through `window._setContent` after `onPageFinished`.
    val shell = remember(payload.stateJson, app.schemaVersion) {
        wrapWidgetHtml(
            widgetHtml = "",
            appState = AppStateInjection(
                stateJson = payload.stateJson,
                schemaVersion = app.schemaVersion,
            ),
        )
    }

    AndroidView(
        factory = { ctx ->
            WebView(ctx).apply {
                webViewRef.value = this
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.loadsImagesAutomatically = true
                settings.builtInZoomControls = false
                settings.displayZoomControls = false
                overScrollMode = WebView.OVER_SCROLL_NEVER
                addJavascriptInterface(savedBridge, SavedAppBridge.INTERFACE_NAME)
                addJavascriptInterface(widgetBridge, WidgetBridge.INTERFACE_NAME)
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView?, url: String?) {
                        super.onPageFinished(view, url)
                        if (view == null) return
                        view.setTag(
                            com.sigkitten.litter.android.R.id.widget_webview_shell_ready,
                            true,
                        )
                        val pending = view.getTag(
                            com.sigkitten.litter.android.R.id.widget_webview_pending_html,
                        ) as? String
                        if (pending != null) {
                            view.setTag(
                                com.sigkitten.litter.android.R.id.widget_webview_pending_html,
                                null,
                            )
                            pushWidgetContent(view, pending, runScripts = true)
                        }
                    }

                    override fun shouldOverrideUrlLoading(
                        view: WebView?,
                        request: WebResourceRequest?,
                    ): Boolean {
                        val url = request?.url?.toString().orEmpty()
                        if (url.isBlank() || url.startsWith("about:")) return false
                        return try {
                            ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            true
                        } catch (_: Exception) {
                            false
                        }
                    }
                }
                loadDataWithBaseURL(
                    "https://widget.local/",
                    shell,
                    "text/html",
                    "utf-8",
                    null,
                )
            }
        },
        modifier = Modifier
            .fillMaxSize()
            .alpha(if (dimmed) 0.55f else 1f),
        update = { webView ->
            val html = payload.widgetHtml
            val lastEscaped = webView.getTag(
                com.sigkitten.litter.android.R.id.widget_webview_last_escaped,
            ) as? String
            val escaped = escapeJsString(html)
            if (escaped == lastEscaped) return@AndroidView
            webView.setTag(
                com.sigkitten.litter.android.R.id.widget_webview_last_escaped,
                escaped,
            )
            val shellReady = webView.getTag(
                com.sigkitten.litter.android.R.id.widget_webview_shell_ready,
            ) as? Boolean ?: false
            if (!shellReady) {
                webView.setTag(
                    com.sigkitten.litter.android.R.id.widget_webview_pending_html,
                    html,
                )
            } else {
                pushWidgetContent(webView, html, runScripts = true)
            }
        },
    )
}

@Composable
private fun LoadingPlaceholder() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            color = LitterTheme.accent,
            strokeWidth = 2.dp,
            modifier = Modifier.size(28.dp),
        )
    }
}

@Composable
private fun BrokenPlaceholder(onDelete: () -> Unit) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(32.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.Warning,
                contentDescription = null,
                tint = LitterTheme.warning,
                modifier = Modifier.size(44.dp),
            )
            Text(
                text = "This app's files are missing",
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.headline.scaled,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Delete it to clear the entry.",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.footnote.scaled,
            )
            TextButton(onClick = onDelete) {
                Text("Delete App", color = LitterTheme.danger)
            }
        }
    }
}

@Composable
private fun FailurePlaceholder(message: String, onRetry: () -> Unit) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(24.dp),
        ) {
            Text(
                text = "Couldn't load this app.",
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.headline.scaled,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = message,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.footnote.scaled,
            )
            TextButton(onClick = onRetry) {
                Icon(Icons.Default.Refresh, contentDescription = null, tint = LitterTheme.accent)
                Spacer(Modifier.width(6.dp))
                Text("Retry", color = LitterTheme.accent)
            }
        }
    }
}

@Composable
private fun ShimmerOverlay() {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val alpha by transition.animateFloat(
        initialValue = 0.25f,
        targetValue = 0.55f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "shimmer-alpha",
    )
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.White.copy(alpha = alpha * 0.05f)),
    ) {
        // Thin progress bar along the top.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 2.dp)
                .clip(RoundedCornerShape(1.dp))
                .background(LitterTheme.accent.copy(alpha = alpha))
                .size(width = 0.dp, height = 2.dp)
                .fillMaxWidth(),
        )
    }
}

@Composable
private fun RenameAppDialog(
    currentTitle: String,
    onDismiss: () -> Unit,
    onRename: (String) -> Unit,
) {
    var newTitle by remember(currentTitle) { mutableStateOf(currentTitle) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename App") },
        text = {
            OutlinedTextField(
                value = newTitle,
                onValueChange = { newTitle = it },
                singleLine = true,
                label = { Text("Title") },
            )
        },
        confirmButton = {
            TextButton(onClick = {
                val trimmed = newTitle.trim().ifBlank { currentTitle }
                onRename(trimmed)
            }) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}
