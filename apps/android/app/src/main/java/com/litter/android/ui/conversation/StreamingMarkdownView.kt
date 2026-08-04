package com.litter.android.ui.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import coil.compose.AsyncImage
import coil.request.ImageRequest
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppMessageRenderBlock

/**
 * Composable that renders streaming assistant messages. Uses
 * [StreamingTextCoordinator] to split text into a stable cached prefix and a
 * small frontier without repeatedly fading the active markdown block; token
 * streams can update faster than a fade can complete, which reads as flicker.
 */
@Composable
fun StreamingMarkdownView(
    text: String,
    itemId: String,
    onRendered: (() -> Unit)? = null,
    bodySize: Float = LitterTextStyle.body,
) {
    val appModel = LocalAppModel.current

    // Compute streaming state — stable prefix blocks are cached, frontier blocks animate
    val streamState = remember(itemId, text) {
        StreamingTextCoordinator.update(
            itemId = itemId,
            text = text,
            parser = appModel.parser,
        )
    }

    LaunchedEffect(text) {
        onRendered?.invoke()
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Render stable prefix blocks (fully opaque, cached)
        if (streamState.stableBlocks.isNotEmpty()) {
            StreamingRenderBlocks(
                blocks = streamState.stableBlocks,
                bodySize = bodySize,
            )
        }

        // Render frontier blocks at full opacity. Re-parsing the frontier is
        // enough motion during streaming; restarting alpha on every token is
        // the visible flicker.
        if (streamState.frontierBlocks.isNotEmpty()) {
            StreamingRenderBlocks(
                blocks = streamState.frontierBlocks,
                bodySize = bodySize,
            )
        }
    }
}

@Composable
private fun StreamingRenderBlocks(
    blocks: List<AppMessageRenderBlock>,
    bodySize: Float,
) {
    blocks.forEach { block ->
        when (block) {
            is AppMessageRenderBlock.Markdown -> {
                if (block.markdown.isNotEmpty()) {
                    StreamingMarkdownText(
                        text = block.markdown,
                        bodySize = bodySize,
                    )
                }
            }
            is AppMessageRenderBlock.CodeBlock -> {
                if (isMathLanguage(block.language)) {
                    StreamingMarkdownText(
                        text = mathMarkdownBlock(block.code),
                        bodySize = bodySize,
                    )
                } else {
                    StreamingCodeBlock(
                        language = block.language,
                        code = block.code,
                        bodySize = bodySize,
                    )
                }
            }
            is AppMessageRenderBlock.InlineImage -> {
                val context = LocalContext.current
                AsyncImage(
                    model = ImageRequest.Builder(context)
                        .data(block.data)
                        .crossfade(false)
                        .build(),
                    contentDescription = "Assistant image",
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 300.dp)
                        .clip(RoundedCornerShape(10.dp)),
                )
            }
        }
    }
}

@Composable
private fun StreamingMarkdownText(
    text: String,
    modifier: Modifier = Modifier,
    bodySize: Float = LitterTextStyle.body,
) {
    SelectableMarkdownText(
        text = text,
        modifier = modifier.fillMaxWidth(),
        bodySize = bodySize,
        usePhysicalDpTextSize = true,
        selectable = false,
    )
}

@Composable
private fun StreamingCodeBlock(
    language: String?,
    code: String,
    modifier: Modifier = Modifier,
    bodySize: Float = LitterTextStyle.body,
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        language?.takeIf { it.isNotBlank() }?.let {
            Text(
                text = it.uppercase(),
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Bold,
            )
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                .padding(10.dp),
        ) {
            if (isDiffLanguage(language)) {
                SyntaxHighlightedDiffBlock(
                    diff = code,
                    titleHint = language,
                    fontSize = LitterTextStyle.caption.sp,
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                SelectableConversationText {
                    Text(
                        text = code,
                        color = LitterTheme.textBody,
                        fontFamily = LitterTheme.monoFont,
                        fontSize = bodySize.scaled,
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                    )
                }
            }
        }
    }
}
