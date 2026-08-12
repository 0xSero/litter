package com.litter.android.ui.conversation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.scaled
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private sealed interface ResolvedChatImageState {
    data object Loading : ResolvedChatImageState
    data class Loaded(val data: ByteArray) : ResolvedChatImageState
    data class Failed(val message: String) : ResolvedChatImageState
}

@Composable
internal fun InlineChatImage(
    data: ByteArray,
    contentDescription: String,
    modifier: Modifier = Modifier,
    maxHeight: Dp = 320.dp,
) {
    val context = LocalContext.current
    AsyncImage(
        model = ImageRequest.Builder(context)
            .data(data)
            .crossfade(false)
            .build(),
        contentDescription = contentDescription,
        contentScale = ContentScale.Fit,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(max = maxHeight)
            .clip(RoundedCornerShape(10.dp)),
    )
}

@Composable
internal fun ResolvedChatImage(
    path: String,
    serverId: String,
    cwd: String?,
    modifier: Modifier = Modifier,
    maxHeight: Dp = 320.dp,
) {
    val appModel = LocalAppModel.current
    val state by produceState<ResolvedChatImageState>(
        initialValue = ResolvedChatImageState.Loading,
        path,
        serverId,
        cwd,
    ) {
        value = try {
            val resolved = withContext(Dispatchers.IO) {
                appModel.client.resolveImageViewAt(serverId, path, cwd)
            }
            if (resolved.bytes.isEmpty()) {
                ResolvedChatImageState.Failed("Image data was empty.")
            } else {
                ResolvedChatImageState.Loaded(resolved.bytes)
            }
        } catch (error: Exception) {
            ResolvedChatImageState.Failed(
                error.message?.trim()?.takeIf(String::isNotEmpty) ?: "Image unavailable",
            )
        }
    }

    Box(
        modifier = modifier.fillMaxWidth(),
        contentAlignment = Alignment.Center,
    ) {
        when (val current = state) {
            ResolvedChatImageState.Loading -> CircularProgressIndicator(
                color = LitterTheme.accent,
                strokeWidth = 2.dp,
                modifier = Modifier.padding(vertical = 28.dp),
            )

            is ResolvedChatImageState.Loaded -> InlineChatImage(
                data = current.data,
                contentDescription = "Assistant image ${path.substringAfterLast('/')}",
                maxHeight = maxHeight,
            )

            is ResolvedChatImageState.Failed -> Text(
                text = current.message,
                color = LitterTheme.danger,
                fontSize = LitterTextStyle.caption.scaled,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 24.dp),
            )
        }
    }
}
