package com.litter.android.ui.conversation

import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppThreadSnapshot

/** Floating conversation navigation; model and mode controls live in the composer. */
@Composable
fun HeaderBar(
    thread: AppThreadSnapshot?,
    onBack: () -> Unit,
    onInfo: (() -> Unit)? = null,
    onReloadError: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val server = remember(snapshot, thread) {
        thread?.let { current -> snapshot?.servers?.find { it.serverId == current.key.serverId } }
    }
    var isReloading by remember { mutableStateOf(false) }

    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloatingHeaderButton(onClick = onBack) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = LitterTheme.textPrimary,
                modifier = Modifier.size(20.dp),
            )
        }

        Spacer(Modifier.weight(1f))

        FloatingHeaderButton(
            enabled = !isReloading && thread != null,
            onClick = {
                val currentThread = thread ?: return@FloatingHeaderButton
                scope.launch {
                    isReloading = true
                    try {
                        if (server?.requiresOpenaiAuth == true && server.account == null) {
                            val authUrl = appModel.client.startRemoteSshOauthLogin(currentThread.key.serverId)
                            CustomTabsIntent.Builder().setShowTitle(true).build()
                                .launchUrl(context, Uri.parse(authUrl))
                        } else {
                            val nextKey = appModel.refreshThreadIncludingTurns(currentThread.key)
                            appModel.store.setActiveThread(nextKey)
                        }
                    } catch (error: Exception) {
                        onReloadError?.invoke(error.message ?: "Failed to reload conversation")
                    } finally {
                        isReloading = false
                    }
                }
            },
        ) {
            if (isReloading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = LitterTheme.accent,
                )
            } else {
                Icon(
                    Icons.Default.Refresh,
                    contentDescription = "Reload",
                    tint = LitterTheme.textSecondary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        if (onInfo != null) {
            FloatingHeaderButton(onClick = onInfo) {
                Icon(
                    Icons.Outlined.Info,
                    contentDescription = "Info",
                    tint = LitterTheme.textSecondary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun FloatingHeaderButton(
    onClick: () -> Unit,
    enabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(LitterTheme.surface.copy(alpha = 0.86f)),
        content = content,
    )
}

/** Shared fast-tier override selected from the model options sheet. */
object HeaderOverrides {
    var pendingFastMode by mutableStateOf(false)
}
