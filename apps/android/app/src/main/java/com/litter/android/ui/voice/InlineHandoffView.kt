package com.litter.android.ui.voice

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.rememberStickyFollowTail
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.ThreadKey

/**
 * Compact transcript view of a handoff subagent thread.
 * Shown inline during voice session when handoff is active.
 */
@Composable
fun InlineHandoffView(
    threadKey: ThreadKey,
    modifier: Modifier = Modifier,
) {
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()

    val items = remember(snapshot, threadKey) {
        snapshot?.threads?.find { it.key == threadKey }
            ?.hydratedConversationItems
            ?: emptyList()
    }

    val listState = rememberLazyListState()
    val shouldFollowTail = rememberStickyFollowTail(
        listState = listState,
        resetKey = threadKey,
        bufferItems = 1,
    )
    val tailContentSignature = remember(items) {
        var hash = 17
        items.takeLast(4).forEach { item ->
            hash = 31 * hash + item.hashCode()
        }
        hash = 31 * hash + items.size
        hash
    }

    LaunchedEffect(threadKey, tailContentSignature) {
        if (shouldFollowTail && items.isNotEmpty()) {
            listState.scrollToItem(items.lastIndex)
        }
    }

    LazyColumn(
        state = listState,
        modifier = modifier
            .background(LitterTheme.surface, RoundedCornerShape(12.dp))
            .padding(8.dp),
    ) {
        items(items, key = { it.id }) { item ->
            when (val content = item.content) {
                is HydratedConversationItemContent.User -> {
                    Text(
                        text = content.v1.text,
                        color = LitterTheme.textPrimary,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(vertical = 2.dp),
                    )
                }

                is HydratedConversationItemContent.Assistant -> {
                    Text(
                        text = content.v1.text,
                        color = LitterTheme.textPrimary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.padding(vertical = 2.dp),
                    )
                }

                is HydratedConversationItemContent.CodeReview -> {
                    val text = content.v1.findings.firstOrNull()?.title ?: "Code review"
                    Text(
                        text = "Review: $text",
                        color = LitterTheme.textPrimary,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.padding(vertical = 2.dp),
                    )
                }

                is HydratedConversationItemContent.Reasoning -> {
                    Text(
                        text = content.v1.summary.joinToString(" "),
                        color = LitterTheme.textMuted,
                        fontSize = 13.sp,
                        fontStyle = FontStyle.Italic,
                        modifier = Modifier.padding(vertical = 1.dp),
                    )
                }

                is HydratedConversationItemContent.CommandExecution -> {
                    Text(
                        text = "$ ${content.v1.command}",
                        color = LitterTheme.toolCallCommand,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(vertical = 1.dp),
                    )
                }

                is HydratedConversationItemContent.ImageView -> {
                    Text(
                        text = "Viewed image: ${content.v1.path.substringAfterLast('/')}",
                        color = LitterTheme.textMuted,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(vertical = 1.dp),
                    )
                }

                is HydratedConversationItemContent.Note -> {
                    Text(
                        text = content.v1.body,
                        color = LitterTheme.danger,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(vertical = 1.dp),
                    )
                }

                else -> {} // Skip other types in compact view
            }
        }
    }
}
