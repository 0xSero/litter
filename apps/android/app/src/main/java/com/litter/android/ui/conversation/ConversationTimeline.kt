package com.litter.android.ui.conversation

import android.annotation.SuppressLint
import android.content.Intent
import com.sigkitten.litter.android.R
import androidx.compose.foundation.ExperimentalFoundationApi
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.SavedAppsStore
import com.litter.android.ui.BerkeleyMono
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalTextScale
import com.litter.android.ui.scaled
import com.litter.android.state.AppModel
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import uniffi.codex_mobile_client.AppMessageRenderBlock
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.HydratedPlanStepStatus
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private const val ToolCallTextPreviewLimit = 2_000
private const val UserMessageTextPreviewLimit = 1_000

/**
 * Renders a single [HydratedConversationItem] by matching on its content type.
 * Uses Rust-provided types directly — no intermediate model conversion.
 */
@Composable
fun ConversationTimelineItem(
    item: HydratedConversationItem,
    serverId: String,
    threadId: String,
    agentDirectoryVersion: ULong,
    latestCommandExecutionItemId: String? = null,
    isLiveTurn: Boolean = false,
    isStreamingMessage: Boolean = false,
    onStreamingSnapshotRendered: (() -> Unit)? = null,
    onEditMessage: ((UInt) -> Unit)? = null,
    onForkFromMessage: ((UInt) -> Unit)? = null,
    onOpenSavedApp: ((String) -> Unit)? = null,
    onWidgetPrompt: ((String) -> Unit)? = null,
) {
    val shouldNotifyLiveContentRendered = remember(item.content, isLiveTurn) {
        isLiveTurn && item.content.shouldAutoFollowRenderedContent()
    }

    LaunchedEffect(item.id, item.hashCode(), shouldNotifyLiveContentRendered) {
        if (!shouldNotifyLiveContentRendered) return@LaunchedEffect
        delay(32)
        onStreamingSnapshotRendered?.invoke()
    }

    when (val content = item.content) {
        is HydratedConversationItemContent.User -> UserMessageRow(
            data = content.v1,
            turnIndex = item.sourceTurnIndex ?: 0u,
            onEdit = onEditMessage,
            onFork = onForkFromMessage,
        )

        is HydratedConversationItemContent.Assistant -> AssistantMessageRow(
            itemId = item.id,
            data = content.v1,
            serverId = serverId,
            agentDirectoryVersion = agentDirectoryVersion,
            isStreamingMessage = isStreamingMessage,
            onStreamingSnapshotRendered = onStreamingSnapshotRendered,
        )

        is HydratedConversationItemContent.CodeReview -> CodeReviewRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Reasoning -> ReasoningRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.CommandExecution -> CommandExecutionRow(
            data = content.v1,
            keepExpanded = item.id == latestCommandExecutionItemId ||
                content.v1.status == AppOperationStatus.PENDING ||
                content.v1.status == AppOperationStatus.IN_PROGRESS,
        )

        is HydratedConversationItemContent.FileChange -> FileChangeRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.TurnDiff -> TurnDiffRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.TodoList -> TodoListRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.ProposedPlan -> ProposedPlanRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.McpToolCall -> {
            val cu = content.v1.computerUse
            if (cu != null) {
                ComputerUseToolCallRow(data = content.v1, view = cu)
            } else {
                McpToolCallRow(data = content.v1)
            }
        }

        is HydratedConversationItemContent.DynamicToolCall -> DynamicToolCallRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.MultiAgentAction -> {
            SubagentCard(data = content.v1, serverId = serverId)
        }

        is HydratedConversationItemContent.WebSearch -> WebSearchRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.ImageView -> ImageViewRow(
            data = content.v1,
            serverId = serverId,
        )

        is HydratedConversationItemContent.ImageGeneration -> ImageGenerationRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Widget -> WidgetRow(
            data = content.v1,
            originThreadId = threadId,
            onOpenSavedApp = onOpenSavedApp,
            onWidgetPrompt = onWidgetPrompt,
        )

        is HydratedConversationItemContent.UserInputResponse -> UserInputResponseRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Divider -> DividerRow(
            data = content.v1,
            isLiveTurn = isLiveTurn,
        )

        is HydratedConversationItemContent.Error -> ErrorRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Note -> NoteRow(
            data = content.v1,
        )
    }
}

private fun HydratedConversationItemContent.shouldAutoFollowRenderedContent(): Boolean {
    return when (this) {
        is HydratedConversationItemContent.Reasoning,
        is HydratedConversationItemContent.CommandExecution,
        is HydratedConversationItemContent.FileChange,
        is HydratedConversationItemContent.TurnDiff,
        is HydratedConversationItemContent.McpToolCall,
        is HydratedConversationItemContent.DynamicToolCall,
        is HydratedConversationItemContent.MultiAgentAction,
        is HydratedConversationItemContent.WebSearch,
        is HydratedConversationItemContent.ImageView,
        is HydratedConversationItemContent.ImageGeneration,
        is HydratedConversationItemContent.Widget -> true
        else -> false
    }
}

// ── User Message ─────────────────────────────────────────────────────────────

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun UserMessageRow(
    data: uniffi.codex_mobile_client.HydratedUserMessageData,
    turnIndex: UInt,
    onEdit: ((UInt) -> Unit)?,
    onFork: ((UInt) -> Unit)?,
) {
    var showMenu by remember { mutableStateOf(false) }
    val context = LocalContext.current

    // Right-aligned user bubble matching iOS `UserBubble`: accent-tinted
    // rounded rect that hugs content width, with a 60dp minimum gutter on
    // the left so long messages wrap before reaching that edge.
    //
    // Long-press opens an action menu (Edit / Fork / Copy). Text selection is
    // disabled on user bubbles because Compose's SelectionContainer would
    // consume the long-press gesture before our handler sees it; copy is
    // exposed via the menu instead.
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 10.dp, bottom = 14.dp),
        horizontalArrangement = Arrangement.End,
    ) {
        Box {
            Column(
                horizontalAlignment = Alignment.End,
                modifier = Modifier
                    .padding(start = 60.dp)
                    .background(
                        LitterTheme.accent.copy(alpha = 0.3f),
                        RoundedCornerShape(18.dp),
                    )
                    .combinedClickable(
                        onClick = {},
                        onLongClick = { showMenu = true },
                    )
                    .padding(horizontal = 18.dp, vertical = 14.dp),
            ) {
                LimitedUserMessageText(data.text)
                // Inline images from data URIs
                for (uri in data.imageDataUris) {
                    val bitmap = remember(uri) {
                        try {
                            val base64Part = uri.substringAfter("base64,", "")
                            if (base64Part.isNotEmpty()) {
                                val bytes = Base64.decode(base64Part, Base64.DEFAULT)
                                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                            } else null
                        } catch (_: Exception) { null }
                    }
                    bitmap?.let {
                        Image(
                            bitmap = it.asImageBitmap(),
                            contentDescription = "Attached image",
                            modifier = Modifier
                                .padding(top = 4.dp)
                                .heightIn(max = 200.dp)
                                .clip(RoundedCornerShape(8.dp)),
                        )
                    }
                }
            }
            DropdownMenu(
                expanded = showMenu,
                onDismissRequest = { showMenu = false },
            ) {
                if (onEdit != null) {
                    DropdownMenuItem(
                        text = { Text("Edit Message") },
                        onClick = { showMenu = false; onEdit(turnIndex) },
                    )
                }
                if (onFork != null) {
                    DropdownMenuItem(
                        text = { Text("Fork From Here") },
                        onClick = { showMenu = false; onFork(turnIndex) },
                    )
                }
                DropdownMenuItem(
                    text = { Text("Copy") },
                    onClick = {
                        showMenu = false
                        val cm = context.getSystemService(android.content.Context.CLIPBOARD_SERVICE)
                            as android.content.ClipboardManager
                        cm.setPrimaryClip(android.content.ClipData.newPlainText("message", data.text))
                    },
                )
            }
        }
    }
}

@Composable
private fun LimitedUserMessageText(text: String) {
    val isLong = text.length > UserMessageTextPreviewLimit
    var expanded by remember(text) { mutableStateOf(false) }
    val display = remember(text, expanded) {
        if (isLong && !expanded) text.take(UserMessageTextPreviewLimit) else text
    }

    com.litter.android.ui.common.FormattedText(
        text = display,
        color = LitterTheme.textPrimary,
        fontSize = LitterTextStyle.callout.scaled,
    )

    if (isLong) {
        Text(
            text = if (expanded) "Show less" else "Show more",
            color = LitterTheme.accent,
            fontSize = LitterTextStyle.caption2.scaled,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier
                .padding(top = 4.dp)
                .clickable { expanded = !expanded },
        )
    }
}

// ── Assistant Message ────────────────────────────────────────────────────────

@Composable
private fun AssistantMessageRow(
    itemId: String,
    data: uniffi.codex_mobile_client.HydratedAssistantMessageData,
    serverId: String,
    agentDirectoryVersion: ULong,
    isStreamingMessage: Boolean,
    onStreamingSnapshotRendered: (() -> Unit)?,
) {
    val appModel = LocalAppModel.current
    val renderBlocks = remember(itemId, data.text, serverId, agentDirectoryVersion, isStreamingMessage) {
        if (isStreamingMessage) {
            emptyList()
        } else {
            MessageRenderCache.getRenderBlocks(
                key = MessageRenderCache.CacheKey(
                    itemId = itemId,
                    revisionToken = data.text.hashCode(),
                    serverId = serverId,
                    agentDirectoryVersion = agentDirectoryVersion,
                ),
                parser = appModel.parser,
                text = data.text,
            )
        }
    }
    var renderedText by remember(itemId) { mutableStateOf(data.text) }
    var pendingText by remember(itemId) { mutableStateOf<String?>(null) }

    LaunchedEffect(itemId) {
        renderedText = data.text
        pendingText = null
        if (isStreamingMessage) {
            onStreamingSnapshotRendered?.invoke()
        }
    }

    LaunchedEffect(data.text, isStreamingMessage) {
        if (!isStreamingMessage) {
            renderedText = data.text
            pendingText = null
            StreamingTextCoordinator.evict(itemId)
            return@LaunchedEffect
        }
        if (data.text == renderedText) return@LaunchedEffect
        if (renderedText.isEmpty()) {
            renderedText = data.text
            onStreamingSnapshotRendered?.invoke()
        } else {
            pendingText = data.text
        }
    }

    LaunchedEffect(pendingText, isStreamingMessage) {
        val nextText = pendingText ?: return@LaunchedEffect
        if (!isStreamingMessage) return@LaunchedEffect
        delay(60)
        renderedText = nextText
        pendingText = null
        onStreamingSnapshotRendered?.invoke()
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        // Agent badge
        if (data.agentNickname != null || data.agentRole != null) {
            val label = buildString {
                data.agentNickname?.let { append(it) }
                data.agentRole?.let {
                    if (isNotEmpty()) append(" ")
                    append("[$it]")
                }
            }
            Text(
                text = label,
                color = LitterTheme.accent,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.height(2.dp))
        }

        if (isStreamingMessage) {
            StreamingMarkdownView(
                text = renderedText,
                itemId = itemId,
                onRendered = onStreamingSnapshotRendered,
            )
        } else {
            AssistantRenderBlocks(
                blocks = renderBlocks,
                fallbackText = renderedText,
            )
        }
    }
}

@Composable
private fun AssistantRenderBlocks(
    blocks: List<AppMessageRenderBlock>,
    fallbackText: String,
) {
    if (blocks.isEmpty()) {
        MarkdownText(text = fallbackText)
        return
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        blocks.forEachIndexed { index, block ->
            when (block) {
                is AppMessageRenderBlock.Markdown -> MarkdownText(text = block.markdown)
                is AppMessageRenderBlock.CodeBlock -> CodeBlockSegment(
                    language = block.language,
                    code = block.code,
                )
                is AppMessageRenderBlock.InlineImage -> {
                    val bitmap = remember(block.data) {
                        BitmapFactory.decodeByteArray(block.data, 0, block.data.size)
                    }
                    bitmap?.let {
                        Image(
                            bitmap = it.asImageBitmap(),
                            contentDescription = "Assistant image ${index + 1}",
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 300.dp)
                                .clip(RoundedCornerShape(10.dp)),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CodeReviewRow(
    data: uniffi.codex_mobile_client.HydratedCodeReviewData,
) {
    var dismissedIndices by remember(data.findings) { mutableStateOf(setOf<Int>()) }
    val visibleFindings = remember(data.findings, dismissedIndices) {
        data.findings.mapIndexedNotNull { index, finding ->
            if (dismissedIndices.contains(index)) null else index to finding
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        visibleFindings.forEach { (index, finding) ->
            CodeReviewFindingCard(
                finding = finding,
                onDismiss = { dismissedIndices = dismissedIndices + index },
            )
        }
    }
}

@Composable
private fun CodeReviewFindingCard(
    finding: uniffi.codex_mobile_client.HydratedCodeReviewFindingData,
    onDismiss: () -> Unit,
) {
    val priorityTint = when (finding.priority?.toInt()) {
        0, 1 -> LitterTheme.danger
        2 -> LitterTheme.warning
        3 -> LitterTheme.textSecondary
        else -> LitterTheme.textSecondary
    }
    val locationText = remember(finding.codeLocation) {
        val location = finding.codeLocation ?: return@remember null
        val range = location.lineRange
        when {
            range == null -> location.absoluteFilePath
            range.start == range.end -> "${location.absoluteFilePath}:${range.start}"
            else -> "${location.absoluteFilePath}:${range.start}-${range.end}"
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(22.dp))
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            finding.priority?.let { priority ->
                Text(
                    text = "P${priority.toInt()}",
                    color = priorityTint,
                    fontSize = LitterTextStyle.caption2.scaled,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier
                        .background(priorityTint.copy(alpha = 0.12f), RoundedCornerShape(999.dp))
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                )
                Spacer(Modifier.width(10.dp))
            }

            Text(
                text = finding.title,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.callout.scaled,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )

            Text(
                text = "Dismiss",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.callout.scaled,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.clickable(onClick = onDismiss),
            )
        }

        MarkdownText(text = finding.body)

        locationText?.takeIf { it.isNotBlank() }?.let { location ->
            Text(
                text = location,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.footnote.scaled,
                fontFamily = LitterTheme.monoFont,
            )
        }
    }
}

// ── Reasoning ────────────────────────────────────────────────────────────────

@Composable
private fun ReasoningRow(
    data: uniffi.codex_mobile_client.HydratedReasoningData,
) {
    val reasoningText = remember(data.summary, data.content) {
        (data.summary + data.content)
            .filter { it.isNotBlank() }
            .joinToString(separator = "\n\n")
    }

    if (reasoningText.isBlank()) return

    SelectableConversationText(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        Text(
            text = reasoningText,
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.body.scaled,
            fontFamily = LitterTheme.monoFont,
            fontStyle = FontStyle.Italic,
        )
    }
}

// ── Command Execution ────────────────────────────────────────────────────────

@Composable
private fun CommandExecutionRow(
    data: uniffi.codex_mobile_client.HydratedCommandExecutionData,
    keepExpanded: Boolean,
) {
    var expanded by remember(data.command) { mutableStateOf(keepExpanded) }
    val outputScrollState = rememberScrollState()
    val outputText =
        data.output
            ?.trim('\n')
            ?.takeIf { it.isNotBlank() }
            ?: if (data.status == AppOperationStatus.PENDING || data.status == AppOperationStatus.IN_PROGRESS) {
                "Waiting for output…"
            } else {
                "No output"
            }
    val isRunning = data.status == AppOperationStatus.PENDING || data.status == AppOperationStatus.IN_PROGRESS
    val displayedCommand = remember(data.command) { displayCommandText(data.command) }
    val collapsedCommand = remember(data.command) { collapseCommandText(data.command) }

    LaunchedEffect(keepExpanded) {
        expanded = keepExpanded
    }

    LaunchedEffect(outputText, outputScrollState.maxValue, expanded) {
        if (!expanded) return@LaunchedEffect
        if (outputScrollState.maxValue <= 0) return@LaunchedEffect
        outputScrollState.animateScrollTo(outputScrollState.maxValue)
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(12.dp))
            .border(0.5.dp, LitterTheme.border, RoundedCornerShape(12.dp))
            .clickable { expanded = !expanded }
            .padding(horizontal = 12.dp, vertical = 9.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "$",
                color = LitterTheme.warning,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.caption.scaled,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = if (expanded) displayedCommand else collapsedCommand,
                color = LitterTheme.textSystem,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.body.scaled,
                maxLines = if (expanded) Int.MAX_VALUE else 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            data.durationMs?.takeIf { it > 0 }?.let { ms ->
                Spacer(Modifier.width(6.dp))
                DurationChip(formatDuration(ms), statusTint(data.status))
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = if (expanded) "▲" else "▼",
                color = LitterTheme.warning,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Bold,
            )
        }

        if (expanded) {
            Spacer(Modifier.height(6.dp))
            LimitedToolTextBlock(outputText, previewFromTail = isRunning) { display ->
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 116.dp)
                        .background(LitterTheme.codeBackground, RoundedCornerShape(10.dp))
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                ) {
                    SelectableConversationText {
                        Text(
                            text = display,
                            color = LitterTheme.textSecondary,
                            fontFamily = LitterTheme.monoFont,
                            fontSize = LitterTextStyle.body.scaled,
                            modifier = Modifier
                                .fillMaxWidth()
                                .verticalScroll(outputScrollState),
                        )
                    }
                }
            }
        }
    }
}

// ── File Change ──────────────────────────────────────────────────────────────

@Composable
private fun FileChangeRow(
    data: uniffi.codex_mobile_client.HydratedFileChangeData,
) {
    val summary = remember(data.changes) {
        buildFileChangeSummary(data)
    }
    val diffChanges = remember(data.changes) {
        data.changes.filter { it.diff.isNotBlank() }
    }

    ToolCardShell(
        summary = summary.plainText,
        summaryAnnotated = summary.annotatedText,
        accent = LitterTheme.toolCallFileChange,
        status = data.status,
    ) {
        if (diffChanges.isEmpty() && data.changes.isNotEmpty()) {
            ListSection("Files", data.changes.map { workspaceTitle(it.path) })
        }
        diffChanges.forEach { change ->
            DiffSection(
                label = if (diffChanges.size > 1) workspaceTitle(change.path) else "",
                content = change.diff,
            )
        }
    }
}

private data class FileChangeSummary(
    val plainText: String,
    val annotatedText: AnnotatedString,
)

private fun buildFileChangeSummary(
    data: uniffi.codex_mobile_client.HydratedFileChangeData,
): FileChangeSummary {
    if (data.changes.isEmpty()) {
        return FileChangeSummary(
            plainText = "File changes",
            annotatedText = AnnotatedString("File changes"),
        )
    }

    val additions = data.changes.sumOf { it.additions.toInt() }
    val deletions = data.changes.sumOf { it.deletions.toInt() }
    val hasCountSummary = additions > 0 || deletions > 0

    if (data.changes.size == 1) {
        val change = data.changes.first()
        val verb = fileChangeVerb(change.kind)
        val filename = workspaceTitle(change.path)
        if (!hasCountSummary) {
            return FileChangeSummary(
                plainText = "$verb $filename",
                annotatedText = AnnotatedString("$verb $filename"),
            )
        }
        val plainText = "$verb $filename +$additions -$deletions"
        val annotatedText = buildAnnotatedString {
            withStyle(SpanStyle(color = LitterTheme.textSecondary)) {
                append("$verb ")
            }
            withStyle(SpanStyle(color = LitterTheme.accent)) {
                append(filename)
            }
            withStyle(SpanStyle(color = LitterTheme.success)) {
                append(" +$additions")
            }
            withStyle(SpanStyle(color = LitterTheme.danger)) {
                append(" -$deletions")
            }
        }
        return FileChangeSummary(plainText = plainText, annotatedText = annotatedText)
    }

    if (!hasCountSummary) {
        return FileChangeSummary(
            plainText = "Changed ${data.changes.size} files",
            annotatedText = AnnotatedString("Changed ${data.changes.size} files"),
        )
    }

    val plainText = "Changed ${data.changes.size} files +$additions -$deletions"
    val annotatedText = buildAnnotatedString {
        append("Changed ${data.changes.size} files")
        withStyle(SpanStyle(color = LitterTheme.success)) {
            append(" +$additions")
        }
        withStyle(SpanStyle(color = LitterTheme.danger)) {
            append(" -$deletions")
        }
    }
    return FileChangeSummary(plainText = plainText, annotatedText = annotatedText)
}

private fun fileChangeVerb(kind: String): String = when (kind.lowercase()) {
    "add" -> "Added"
    "delete" -> "Deleted"
    "update" -> "Edited"
    else -> "Changed"
}

// ── Todo List ────────────────────────────────────────────────────────────────

@Composable
private fun TodoListRow(
    data: uniffi.codex_mobile_client.HydratedTodoListData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
    ) {
        for (step in data.steps) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(vertical = 1.dp),
            ) {
                val icon = when (step.status) {
                    HydratedPlanStepStatus.COMPLETED -> "✓"
                    HydratedPlanStepStatus.IN_PROGRESS -> "●"
                    HydratedPlanStepStatus.PENDING -> "○"
                }
                val color = when (step.status) {
                    HydratedPlanStepStatus.COMPLETED -> LitterTheme.success
                    HydratedPlanStepStatus.IN_PROGRESS -> LitterTheme.accent
                    HydratedPlanStepStatus.PENDING -> LitterTheme.textMuted
                }
                Text(text = icon, color = color, fontSize = LitterTextStyle.footnote.scaled)
                Spacer(Modifier.width(6.dp))
                Text(
                    text = step.step,
                    color = LitterTheme.textBody,
                    fontSize = LitterTextStyle.body.scaled,
                )
            }
        }
    }
}

// ── Proposed Plan ────────────────────────────────────────────────────────────

@Composable
private fun ProposedPlanRow(
    data: uniffi.codex_mobile_client.HydratedProposedPlanData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        Text(
            text = "Plan",
            color = LitterTheme.accent,
            fontSize = LitterTextStyle.caption.scaled,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        MarkdownText(text = data.content)
    }
}

// ── MCP Tool Call ────────────────────────────────────────────────────────────

@Composable
private fun McpToolCallRow(
    data: uniffi.codex_mobile_client.HydratedMcpToolCallData,
) {
    val summary = if (data.server.isBlank()) data.tool else "${data.server}.${data.tool}"
    ToolCardShell(
        summary = summary,
        accent = LitterTheme.toolCallMcpCall,
        status = data.status,
        durationMs = data.durationMs,
    ) {
        data.argumentsJson?.takeIf { it.isNotBlank() }?.let { CodeSection("Arguments", it) }
        data.contentSummary?.takeIf { it.isNotBlank() }?.let { InlineTextSection("Result", it) }
        data.structuredContentJson?.takeIf { it.isNotBlank() }?.let { CodeSection("Structured", it) }
        data.rawOutputJson?.takeIf { it.isNotBlank() }?.let { CodeSection("Raw Output", it) }
        if (data.progressMessages.isNotEmpty()) {
            ProgressSection("Progress", data.progressMessages)
        }
        data.errorMessage?.takeIf { it.isNotBlank() }?.let { InlineTextSection("Error", it, tone = LitterTheme.danger) }
    }
}

// ── Computer Use Tool Call (computer-use MCP) ───────────────────────────────

@Composable
private fun ComputerUseToolCallRow(
    data: uniffi.codex_mobile_client.HydratedMcpToolCallData,
    view: uniffi.codex_mobile_client.ComputerUseView,
) {
    ToolCardShell(
        summary = view.summary,
        accent = LitterTheme.toolCallMcpCall,
        status = data.status,
        durationMs = data.durationMs,
    ) {
        view.screenshotPng?.let { bytes ->
            ScreenshotPreview(bytes)
        }
        data.errorMessage?.takeIf { it.isNotBlank() }?.let {
            InlineTextSection("Error", it, tone = LitterTheme.danger)
        }
        view.accessibilityText?.takeIf { it.isNotBlank() }?.let {
            AccessibilityTreeSection(it)
        }
    }
}

@Composable
private fun ScreenshotPreview(bytes: ByteArray) {
    val bitmap = remember(bytes) {
        try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        } catch (_: Throwable) {
            null
        }
    }
    if (bitmap == null) {
        InlineTextSection("Screenshot", "Unavailable", tone = LitterTheme.textMuted)
        return
    }
    Column {
        Text(
            text = "SCREENSHOT",
            color = LitterTheme.textSecondary,
            fontSize = 10f.scaled,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(4.dp))
        Image(
            bitmap = bitmap,
            contentDescription = "Computer Use screenshot",
            contentScale = ContentScale.Fit,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(LitterTheme.codeBackground),
        )
    }
}

@Composable
private fun AccessibilityTreeSection(text: String) {
    var expanded by remember(text) { mutableStateOf(false) }
    val lines = remember(text) { text.split('\n') }
    val previewLineCount = 6
    val display = if (expanded || lines.size <= previewLineCount) {
        text
    } else {
        lines.take(previewLineCount).joinToString("\n") + "\n… (${lines.size - previewLineCount} more lines)"
    }

    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "ACCESSIBILITY TREE",
                color = LitterTheme.textSecondary,
                fontSize = 10f.scaled,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f),
            )
            if (lines.size > previewLineCount) {
                Text(
                    text = if (expanded) "Show less" else "Show more",
                    color = LitterTheme.accent,
                    fontSize = 10f.scaled,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.clickable { expanded = !expanded },
                )
            }
        }
        Spacer(Modifier.height(4.dp))
        Text(
            text = display,
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.caption2.scaled,
            fontFamily = BerkeleyMono,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(LitterTheme.codeBackground)
                .padding(10.dp),
        )
    }
}

// ── Dynamic Tool Call ────────────────────────────────────────────────────────

@Composable
private fun DynamicToolCallRow(
    data: uniffi.codex_mobile_client.HydratedDynamicToolCallData,
) {
    val richPayload = remember(data.tool, data.contentSummary) {
        decodeRichDynamicToolPayload(data.tool, data.contentSummary)
    }
    if (richPayload != null) {
        RichDynamicToolResult(payload = richPayload)
        return
    }

    val display = data.display
    val summary = display?.summary?.takeIf { it.isNotBlank() }
        ?: data.namespace?.takeIf { it.isNotBlank() }?.let { "$it.${data.tool}" }
        ?: data.tool
    val metadata = buildList {
        display?.metadata?.forEach { entry ->
            add(entry.key to entry.value)
        }
        data.namespace?.takeIf { it.isNotBlank() }?.let { add("Namespace" to it) }
        data.success?.let { add("Success" to it.toString()) }
    }
    ToolCardShell(
        summary = summary,
        accent = LitterTheme.toolCallMcpCall,
        status = data.status,
        durationMs = data.durationMs,
    ) {
        if (metadata.isNotEmpty()) {
            KeyValueSection(label = "Metadata", entries = metadata)
        }
        data.argumentsJson?.takeIf { it.isNotBlank() }?.let { CodeSection("Arguments", it) }
        data.contentSummary?.takeIf { it.isNotBlank() }?.let { InlineTextSection("Result", it) }
    }
}

// ── Web Search ───────────────────────────────────────────────────────────────

@Composable
private fun WebSearchRow(
    data: uniffi.codex_mobile_client.HydratedWebSearchData,
) {
    ToolCardShell(
        summary = if (data.query.isBlank()) "Web search" else "Web search for ${data.query}",
        accent = LitterTheme.toolCallWebSearch,
        status = if (data.isInProgress) AppOperationStatus.IN_PROGRESS else AppOperationStatus.COMPLETED,
    ) {
        if (data.query.isNotBlank()) {
            InlineTextSection("Query", data.query)
        }
        data.actionJson?.takeIf { it.isNotBlank() }?.let { CodeSection("Action", it) }
    }
}

@Composable
private fun ImageViewRow(
    data: uniffi.codex_mobile_client.HydratedImageViewData,
    serverId: String,
) {
    ToolCardShell(
        summary = workspaceTitle(data.path),
        accent = LitterTheme.warning,
        status = AppOperationStatus.COMPLETED,
        defaultExpanded = true,
    ) {
        ImageResultSection(path = data.path, serverId = serverId)
        KeyValueSection("Metadata", listOf("Path" to data.path))
    }
}

@Composable
private fun ImageGenerationRow(
    data: uniffi.codex_mobile_client.HydratedImageGenerationData,
) {
    val summary = when (data.status) {
        AppOperationStatus.COMPLETED -> "Generated image"
        AppOperationStatus.FAILED -> "Image generation failed"
        else -> "Generating image…"
    }
    ToolCardShell(
        summary = summary,
        accent = LitterTheme.accent,
        status = data.status,
        defaultExpanded = true,
    ) {
        GeneratedImageSection(data = data)
        data.revisedPrompt?.takeIf { it.isNotBlank() }?.let { prompt ->
            RevisedPromptSection(prompt)
        }
        data.savedPath?.takeIf { it.isNotBlank() }?.let { path ->
            KeyValueSection("Metadata", listOf("Saved to" to path))
        }
    }
}

@Composable
private fun GeneratedImageSection(
    data: uniffi.codex_mobile_client.HydratedImageGenerationData,
) {
    val bitmap = remember(data.imagePng) {
        val bytes = data.imagePng ?: return@remember null
        try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        } catch (_: Throwable) {
            null
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel("Image")
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(10.dp))
                .padding(horizontal = 10.dp, vertical = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            when {
                bitmap != null -> {
                    Image(
                        bitmap = bitmap,
                        contentDescription = "Generated image",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 360.dp)
                            .clip(RoundedCornerShape(8.dp)),
                    )
                }
                data.status == AppOperationStatus.IN_PROGRESS ||
                    data.status == AppOperationStatus.PENDING -> {
                    GeneratedImageLoadingTile()
                }
                else -> {
                    Text(
                        text = "Image unavailable",
                        color = LitterTheme.textMuted,
                        fontSize = LitterTextStyle.caption.scaled,
                        modifier = Modifier.padding(vertical = 20.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun GeneratedImageLoadingTile() {
    val transition = rememberInfiniteTransition(label = "image-generation-loading")
    val pulse by transition.animateFloat(
        initialValue = 0.35f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "image-generation-pulse",
    )

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 20.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(48.dp)
                .scale(0.98f + pulse * 0.05f)
                .background(
                    Brush.linearGradient(
                        colors = listOf(
                            LitterTheme.accent.copy(alpha = 0.16f + pulse * 0.08f),
                            LitterTheme.warning.copy(alpha = 0.10f),
                        ),
                    ),
                    RoundedCornerShape(12.dp),
                )
                .border(
                    0.5.dp,
                    LitterTheme.accent.copy(alpha = 0.28f + pulse * 0.12f),
                    RoundedCornerShape(12.dp),
                ),
        ) {
            Icon(
                imageVector = Icons.Filled.HourglassEmpty,
                contentDescription = null,
                tint = LitterTheme.accent,
                modifier = Modifier.size(22.dp),
            )
        }

        Text(
            text = "Generating image",
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.caption.scaled,
            fontWeight = FontWeight.SemiBold,
        )

        Row(
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            listOf(28.dp, 42.dp, 28.dp).forEachIndexed { index, width ->
                Box(
                    modifier = Modifier
                        .width(width)
                        .height(4.dp)
                        .alpha((0.38f + pulse * 0.62f - index * 0.14f).coerceIn(0.24f, 1f))
                        .background(
                            LitterTheme.accent.copy(alpha = 0.42f),
                            RoundedCornerShape(999.dp),
                        ),
                )
            }
        }
    }
}

@Composable
private fun RevisedPromptSection(prompt: String) {
    var expanded by remember(prompt) { mutableStateOf(false) }
    val isLong = prompt.length > 220 || prompt.count { it == '\n' } >= 4
    val display = if (expanded || !isLong) prompt else prompt.take(220).trimEnd() + "…"

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionLabel("Revised Prompt")
            Spacer(Modifier.weight(1f))
            if (isLong) {
                Text(
                    text = if (expanded) "Show less" else "Show more",
                    color = LitterTheme.accent,
                    fontSize = LitterTextStyle.caption2.scaled,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.clickable { expanded = !expanded },
                )
            }
        }
        Text(
            text = display,
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.body.scaled,
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                .padding(10.dp),
        )
    }
}

private sealed interface ToolImageLoadState {
    data object Loading : ToolImageLoadState
    data class Loaded(val bitmap: android.graphics.Bitmap) : ToolImageLoadState
    data class Failed(val message: String) : ToolImageLoadState
}

@Composable
private fun ImageResultSection(
    path: String,
    serverId: String,
) {
    val appModel = LocalAppModel.current
    val loadState by produceState<ToolImageLoadState>(
        initialValue = ToolImageLoadState.Loading,
        path,
        serverId,
    ) {
        value = ToolImageLoadState.Loading
        value = loadToolImage(appModel, path, serverId)
    }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel("Image")
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(10.dp))
                .padding(horizontal = 10.dp, vertical = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            when (val state = loadState) {
                ToolImageLoadState.Loading -> {
                    CircularProgressIndicator(
                        color = LitterTheme.accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.padding(vertical = 24.dp),
                    )
                }

                is ToolImageLoadState.Loaded -> {
                    Image(
                        bitmap = state.bitmap.asImageBitmap(),
                        contentDescription = workspaceTitle(path),
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 320.dp)
                            .clip(RoundedCornerShape(8.dp)),
                    )
                }

                is ToolImageLoadState.Failed -> {
                    Text(
                        text = state.message,
                        color = LitterTheme.danger,
                        fontSize = LitterTextStyle.caption.scaled,
                        modifier = Modifier.padding(vertical = 20.dp),
                    )
                }
            }
        }
    }
}

private suspend fun loadToolImage(
    appModel: AppModel,
    path: String,
    serverId: String,
): ToolImageLoadState {
    return try {
        val resolved = withContext(Dispatchers.IO) {
            appModel.client.resolveImageView(serverId, path)
        }
        val bitmap = BitmapFactory.decodeByteArray(resolved.bytes, 0, resolved.bytes.size)
        if (bitmap != null) {
            ToolImageLoadState.Loaded(bitmap)
        } else {
            ToolImageLoadState.Failed("Could not decode the image.")
        }
    } catch (error: Exception) {
        val message = error.message?.trim().orEmpty()
        ToolImageLoadState.Failed(
            if (message.isNotEmpty()) message else "Image unavailable",
        )
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun WidgetRow(
    data: uniffi.codex_mobile_client.HydratedWidgetData,
    originThreadId: String?,
    onOpenSavedApp: ((String) -> Unit)?,
    onWidgetPrompt: ((String) -> Unit)?,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val slug = data.appId?.takeIf { it.isNotBlank() }

    // Dynamic height: seeded from the widget's declared height (same
    // `coerceIn(200, 720)` floor/ceiling as before) and then updated by the
    // shell's `_reportHeight` bridge calls once morphdom has rendered.
    val minDp = 200.dp
    val maxDp = 720.dp
    val initialDp = remember(data.height) {
        data.height.coerceIn(200.0, 720.0).roundToInt().dp
    }
    var widgetHeight by remember(minDp, maxDp) { mutableStateOf(initialDp) }
    val density = androidx.compose.ui.platform.LocalDensity.current

    // Callbacks captured once at factory time still see the latest state
    // via these rememberUpdatedState proxies.
    val currentOnWidgetPrompt by androidx.compose.runtime.rememberUpdatedState(onWidgetPrompt)
    val currentIsFinalized by androidx.compose.runtime.rememberUpdatedState(data.isFinalized)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(12.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = data.title.ifBlank { "Widget" },
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.footnote.scaled,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = data.status,
                color = statusTint(
                    when (data.status.lowercase()) {
                        "completed" -> AppOperationStatus.COMPLETED
                        "failed" -> AppOperationStatus.FAILED
                        else -> AppOperationStatus.IN_PROGRESS
                    }
                ),
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Medium,
            )
        }

        AndroidView(
            factory = { ctx ->
                val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
                val bridge = WidgetBridge(
                    onHeight = { reportedPx ->
                        mainHandler.post {
                            val dp = with(density) { reportedPx.toDp() }
                                .coerceIn(minDp, maxDp)
                            if (kotlin.math.abs((dp - widgetHeight).value) > 1f) {
                                widgetHeight = dp
                            }
                        }
                    },
                    onSendPrompt = { text ->
                        mainHandler.post { currentOnWidgetPrompt?.invoke(text) }
                    },
                    onOpenLink = { url ->
                        mainHandler.post {
                            try {
                                ctx.startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(url)),
                                )
                            } catch (_: Exception) {}
                        }
                    },
                    onReady = {
                        // `onPageFinished` also flips the ready flag; this
                        // bridge callback is informational. No-op here.
                    },
                )
                WebView(ctx).apply {
                    setBackgroundColor(android.graphics.Color.TRANSPARENT)
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.loadsImagesAutomatically = true
                    overScrollMode = WebView.OVER_SCROLL_NEVER
                    addJavascriptInterface(bridge, WidgetBridge.INTERFACE_NAME)
                    webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView?, url: String?) {
                            super.onPageFinished(view, url)
                            if (view == null) return
                            view.setTag(R.id.widget_webview_shell_ready, true)
                            val pending = view.getTag(R.id.widget_webview_pending_html) as? String
                            if (pending != null) {
                                view.setTag(R.id.widget_webview_pending_html, null)
                                pushWidgetContent(view, pending, runScripts = currentIsFinalized)
                            }
                        }

                        override fun shouldOverrideUrlLoading(
                            view: WebView?,
                            request: WebResourceRequest?,
                        ): Boolean {
                            val url = request?.url?.toString().orEmpty()
                            if (url.isBlank() || url.startsWith("about:")) {
                                return false
                            }
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
                        wrapWidgetHtml(""),
                        "text/html",
                        "utf-8",
                        null,
                    )
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .height(widgetHeight)
                .clip(RoundedCornerShape(10.dp)),
            update = { webView ->
                val html = data.widgetHtml
                val lastEscaped = webView.getTag(R.id.widget_webview_last_escaped) as? String
                val hasFinalized = webView.getTag(R.id.widget_webview_document) as? Boolean ?: false
                val shellReady = webView.getTag(R.id.widget_webview_shell_ready) as? Boolean ?: false
                val escaped = escapeJsString(html)
                val shouldPush = escaped != lastEscaped || (data.isFinalized && !hasFinalized)
                if (!shouldPush) return@AndroidView
                webView.setTag(R.id.widget_webview_last_escaped, escaped)
                if (data.isFinalized) {
                    webView.setTag(R.id.widget_webview_document, true)
                }
                if (!shellReady) {
                    // Store raw html — `onPageFinished` will push it through
                    // `window._setContent` once morphdom is ready.
                    webView.setTag(R.id.widget_webview_pending_html, html)
                } else {
                    pushWidgetContent(webView, html, runScripts = data.isFinalized)
                }
            },
        )

        if (slug != null && data.isFinalized && originThreadId != null) {
            SavedAsAppChip(
                slug = slug,
                onClick = {
                    scope.launch {
                        val app = try {
                            SavedAppsStore.appForSlug(context, slug, originThreadId)
                        } catch (_: Exception) { null }
                        if (app != null) {
                            onOpenSavedApp?.invoke(app.id)
                        }
                    }
                },
            )
        }
    }
}

/**
 * Push a body-HTML payload into a loaded widget shell via
 * `window._setContent(...)`. When [runScripts] is true (finalized widgets),
 * also invokes `window._runScripts()` so user `<script>` tags inside the
 * widget execute. Mirrors iOS's `coordinator.sendContent(..., runScripts:)`.
 */
internal fun pushWidgetContent(
    webView: WebView,
    html: String,
    runScripts: Boolean,
) {
    val escaped = escapeJsString(html)
    val js = if (runScripts) {
        "window._setContent('$escaped'); window._runScripts();"
    } else {
        "window._setContent('$escaped');"
    }
    webView.evaluateJavascript(js, null)
}

@Composable
private fun SavedAsAppChip(
    slug: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .background(
                LitterTheme.surfaceLight.copy(alpha = 0.5f),
                RoundedCornerShape(6.dp),
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.GridView,
            contentDescription = null,
            tint = LitterTheme.accent,
            modifier = Modifier.size(10.dp),
        )
        Text(
            text = "Saved as",
            color = LitterTheme.accent,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
        )
        Text(
            text = slug,
            color = LitterTheme.accent,
            fontSize = 11.sp,
            fontFamily = LitterTheme.monoFont,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun UserInputResponseRow(
    data: uniffi.codex_mobile_client.HydratedUserInputResponseData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(12.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = "Requested Input",
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.body.scaled,
            fontWeight = FontWeight.SemiBold,
        )

        data.questions.forEach { question ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                question.header?.takeIf { it.isNotBlank() }?.let { header ->
                    Text(
                        text = header.uppercase(),
                        color = LitterTheme.textMuted,
                        fontSize = LitterTextStyle.caption2.scaled,
                        fontWeight = FontWeight.Bold,
                    )
                }
                Text(
                    text = question.question,
                    color = LitterTheme.textPrimary,
                    fontSize = LitterTextStyle.body.scaled,
                    fontWeight = FontWeight.Medium,
                )
                Text(
                    text = question.answer.ifBlank { "No answer provided" },
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.body.scaled,
                )
            }
        }
    }
}

// ── Divider ──────────────────────────────────────────────────────────────────

@Composable
private fun TurnDiffRow(
    data: uniffi.codex_mobile_client.HydratedTurnDiffData,
) {
    ToolCardShell(
        summary = "Turn Diff",
        accent = LitterTheme.toolCallFileChange,
        status = AppOperationStatus.COMPLETED,
    ) {
        DiffSection(label = "Diff", content = data.diff)
    }
}

@Composable
private fun DividerRow(
    data: uniffi.codex_mobile_client.HydratedDividerData,
    isLiveTurn: Boolean,
) {
    val label = when (data) {
        is uniffi.codex_mobile_client.HydratedDividerData.ContextCompaction ->
            if (data.isComplete && !isLiveTurn) "Context compacted" else "Compacting context\u2026"
        is uniffi.codex_mobile_client.HydratedDividerData.ModelRerouted -> {
            val route = data.fromModel?.takeIf { it.isNotBlank() }?.let { "$it -> ${data.toModel}" }
                ?: "Routed to ${data.toModel}"
            val reason = data.reason?.takeIf { it.isNotBlank() }
            if (reason != null) "$route | $reason" else route
        }
        is uniffi.codex_mobile_client.HydratedDividerData.ReviewEntered -> "Review started"
        is uniffi.codex_mobile_client.HydratedDividerData.ReviewExited -> "Review ended"
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HorizontalDivider(
            modifier = Modifier.weight(1f),
            color = LitterTheme.divider,
        )
        Text(
            text = "  $label  ",
            color = LitterTheme.textMuted,
            fontSize = LitterTextStyle.caption2.scaled,
        )
        HorizontalDivider(
            modifier = Modifier.weight(1f),
            color = LitterTheme.divider,
        )
    }
}

// ── Note ─────────────────────────────────────────────────────────────────────

@Composable
private fun NoteRow(
    data: uniffi.codex_mobile_client.HydratedNoteData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .padding(8.dp),
    ) {
        Text(
            text = data.title,
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.body.scaled,
            fontWeight = FontWeight.Medium,
        )
        if (data.body.isNotBlank()) {
            Text(
                text = data.body,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.body.scaled,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

@Composable
private fun ErrorRow(
    data: uniffi.codex_mobile_client.HydratedErrorData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .padding(8.dp),
    ) {
        SelectableConversationText {
            Text(
                text = data.title.ifBlank { "Error" },
                color = LitterTheme.danger,
                fontSize = LitterTextStyle.body.scaled,
                fontWeight = FontWeight.Medium,
            )
            Text(
                text = data.message,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.body.scaled,
                modifier = Modifier.padding(top = 2.dp),
            )
            data.details?.takeIf { it.isNotBlank() }?.let { details ->
                Text(
                    text = details,
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.body.scaled,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
    }
}

// ── Markdown Rendering ───────────────────────────────────────────────────

@Composable
private fun MarkdownText(
    text: String,
    modifier: Modifier = Modifier,
) {
    if (com.litter.android.state.DebugSettings.enabled && com.litter.android.state.DebugSettings.disableMarkdown) {
        SelectableConversationText(modifier = modifier.fillMaxWidth()) {
            Text(
                text = text,
                color = LitterTheme.textBody,
                fontFamily = FontFamily.Monospace,
                fontSize = LitterTextStyle.body.scaled,
            )
        }
        return
    }

    SelectableMarkdownText(
        text = text,
        modifier = modifier.fillMaxWidth(),
    )
}

/**
 * Optional app-mode state injection. When provided, [wrapWidgetHtml] splices a
 * JS block that exposes `window.loadAppState()` / `window.saveAppState(obj)`
 * to the widget script. Leaving it `null` produces the plain timeline shell.
 */
data class AppStateInjection(
    val stateJson: String?,
    val schemaVersion: UInt,
)

/**
 * Timeline widget WebView shell, byte-equivalent (modulo theme tokens and
 * bridge routing) to iOS's [WidgetWebView.buildShellHTML]. The shell is
 * loaded once per WebView; content is pushed in through
 * `window._setContent(html)` / `window._runScripts()` via `evaluateJavascript`
 * — never a full reload. Height reports back through the
 * `__LitterWidgetBridge.height` bridge; `sendPrompt` and `openLink` likewise.
 *
 * When [appState] is provided, a second inline script block is spliced before
 * `window._morphReady = false;` (matching iOS's `buildAppModeShellHTML`
 * splice point) so the saved-app JS bridge (`loadAppState`/`saveAppState`)
 * is available synchronously to user widget scripts on first render.
 */
internal fun wrapWidgetHtml(
    widgetHtml: String,
    appState: AppStateInjection? = null,
): String {
    // Note: `widgetHtml` is not spliced into `<body>` anymore. Callers drive
    // content in through `window._setContent(...)` after the shell loads —
    // see `WidgetRow`/`SavedAppScreen`. We keep the parameter for API
    // compatibility and as a one-shot initial payload via `_pending` for
    // callers who prefer the declarative path.
    val body = widgetHtml.trim()
    val initialPending = if (body.isEmpty()) "null" else "'${escapeJsString(body)}'"
    val appInjection = appState?.let { buildAppStateInjection(it) } ?: ""
    return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1.0">
        <style>
        :root {
            --color-background-primary: #000000;
            --color-background-secondary: #111111;
            --color-background-tertiary: #1a1a1a;
            --color-background-info: #0d253a;
            --color-background-danger: #3a1414;
            --color-background-success: #0d2a14;
            --color-background-warning: #3a2a0d;
            --color-text-primary: #F3F3F3;
            --color-text-secondary: #B3B3B3;
            --color-text-tertiary: #8A8A8A;
            --color-text-info: #00FF9C;
            --color-text-danger: #FF6B6B;
            --color-text-success: #00FF9C;
            --color-text-warning: #FFD166;
            --color-info: var(--color-text-info);
            --color-danger: var(--color-text-danger);
            --color-success: var(--color-text-success);
            --color-warning: var(--color-text-warning);
            --color-border-tertiary: rgba(255,255,255,0.08);
            --color-border-secondary: rgba(255,255,255,0.16);
            --color-border-primary: rgba(255,255,255,0.24);
            --color-border-info: rgba(0,255,156,0.4);
            --color-border-danger: rgba(255,107,107,0.4);
            --color-border-success: rgba(0,255,156,0.4);
            --color-border-warning: rgba(255,209,102,0.4);
            --font-sans: -apple-system, system-ui, Roboto, sans-serif;
            --font-serif: Georgia, 'Times New Roman', serif;
            --font-mono: ui-monospace, SFMono-Regular, Menlo, monospace;
            --border-radius-md: 8px;
            --border-radius-lg: 12px;
            --border-radius-xl: 16px;
            color-scheme: dark;
        }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            padding: 6px;
            font-family: var(--font-sans);
            background: transparent;
            color: var(--color-text-primary);
            font-size: 14px;
            line-height: 1.5;
            -webkit-text-size-adjust: none;
        }
        @keyframes _fadeIn {
            from { opacity: 0; transform: translateY(4px); }
            to { opacity: 1; transform: none; }
        }
        svg { max-width: 100%; height: auto; }
        .t { font-family: var(--font-sans); font-size: 14px; font-weight: 400; fill: var(--color-text-primary); }
        .ts { font-family: var(--font-sans); font-size: 12px; font-weight: 400; fill: var(--color-text-secondary); }
        .th { font-family: var(--font-sans); font-size: 14px; font-weight: 500; fill: var(--color-text-primary); }
        .box { fill: var(--color-background-secondary); stroke: var(--color-border-tertiary); stroke-width: 0.5; }
        .arr { stroke: var(--color-text-tertiary); stroke-width: 1.5; fill: none; }
        .leader { stroke: var(--color-border-tertiary); stroke-width: 0.5; stroke-dasharray: 4 3; fill: none; }
        .node { cursor: pointer; }
        .node:hover { opacity: 0.85; }
        .c-blue > rect, .c-blue > circle, .c-blue > ellipse { fill: #1e3a5f; stroke: rgba(96,165,250,0.4); }
        .c-blue > .t, .c-blue > .th { fill: #93c5fd; }
        .c-blue > .ts { fill: #60a5fa; }
        .c-teal > rect, .c-teal > circle, .c-teal > ellipse { fill: #134e4a; stroke: rgba(45,212,191,0.4); }
        .c-teal > .t, .c-teal > .th { fill: #5eead4; }
        .c-teal > .ts { fill: #2dd4bf; }
        .c-amber > rect, .c-amber > circle, .c-amber > ellipse { fill: #451a03; stroke: rgba(251,191,36,0.4); }
        .c-amber > .t, .c-amber > .th { fill: #fcd34d; }
        .c-amber > .ts { fill: #fbbf24; }
        .c-green > rect, .c-green > circle, .c-green > ellipse { fill: #14532d; stroke: rgba(74,222,128,0.4); }
        .c-green > .t, .c-green > .th { fill: #86efac; }
        .c-green > .ts { fill: #4ade80; }
        .c-red > rect, .c-red > circle, .c-red > ellipse { fill: #450a0a; stroke: rgba(248,113,113,0.4); }
        .c-red > .t, .c-red > .th { fill: #fca5a5; }
        .c-red > .ts { fill: #f87171; }
        .c-purple > rect, .c-purple > circle, .c-purple > ellipse { fill: #2e1065; stroke: rgba(168,85,247,0.4); }
        .c-purple > .t, .c-purple > .th { fill: #c4b5fd; }
        .c-purple > .ts { fill: #a78bfa; }
        .c-coral > rect, .c-coral > circle, .c-coral > ellipse { fill: #431407; stroke: rgba(251,146,60,0.4); }
        .c-coral > .t, .c-coral > .th { fill: #fdba74; }
        .c-coral > .ts { fill: #fb923c; }
        .c-pink > rect, .c-pink > circle, .c-pink > ellipse { fill: #500724; stroke: rgba(244,114,182,0.4); }
        .c-pink > .t, .c-pink > .th { fill: #f9a8d4; }
        .c-pink > .ts { fill: #f472b6; }
        .c-gray > rect, .c-gray > circle, .c-gray > ellipse { fill: var(--color-background-tertiary); stroke: var(--color-border-secondary); }
        .c-gray > .t, .c-gray > .th { fill: var(--color-text-primary); }
        .c-gray > .ts { fill: var(--color-text-secondary); }
        </style>
        </head><body><div id="root"></div>
        <script>
        // Shared message router. Defined before any other shell script (and
        // before the optional app-mode injection) so both paths can call it
        // synchronously. Routes {_type,...} payloads through whichever
        // JS-to-native bridge is present:
        //   - __LitterAppBridge: saved-app saveAppState channel.
        //   - __LitterWidgetBridge: height / sendPrompt / openLink / ready.
        //   - webkit.messageHandlers.widget: iOS fallback (no-op on Android).
        function __postWidgetMessage(msg) {
            try {
                if (msg && msg._type === 'saveAppState'
                    && window.__LitterAppBridge
                    && typeof window.__LitterAppBridge.saveAppState === 'function') {
                    window.__LitterAppBridge.saveAppState(msg.value, msg.schema|0);
                    return true;
                }
                if (msg && msg._type === 'structuredResponse'
                    && window.__LitterAppBridge
                    && typeof window.__LitterAppBridge.structuredResponse === 'function') {
                    // Android @JavascriptInterface only accepts primitives —
                    // stringify the schema object before handing it off. iOS
                    // goes through postMessage and can pass the object as-is.
                    var schemaStr;
                    try { schemaStr = JSON.stringify(msg.responseFormat); }
                    catch (_) { schemaStr = 'null'; }
                    window.__LitterAppBridge.structuredResponse(
                        String(msg.requestId || ''),
                        String(msg.prompt || ''),
                        schemaStr
                    );
                    return true;
                }
                if (window.__LitterWidgetBridge) {
                    var b = window.__LitterWidgetBridge;
                    if (msg._type === 'height' && typeof b.height === 'function') {
                        b.height(msg.value|0);
                        return true;
                    }
                    if (msg._type === 'sendPrompt' && typeof b.sendPrompt === 'function') {
                        b.sendPrompt(String(msg.text || ''));
                        return true;
                    }
                    if (msg._type === 'openLink' && typeof b.openLink === 'function') {
                        b.openLink(String(msg.url || ''));
                        return true;
                    }
                    if (msg._type === 'ready' && typeof b.ready === 'function') {
                        b.ready();
                        return true;
                    }
                }
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.widget) {
                    window.webkit.messageHandlers.widget.postMessage(msg);
                    return true;
                }
            } catch (_) {}
            return false;
        }
        </script>
        $appInjection
        <script>
        window._morphReady = false;
        window._pending = $initialPending;
        window._lastHeight = 0;
        window._heightObserver = null;
        window._reportHeight = function() {
            var r = document.getElementById('root');
            if (!r) return;
            var next = Math.ceil(Math.max(r.offsetHeight, r.scrollHeight)) + 12;
            if (!next || Math.abs(next - window._lastHeight) < 1) return;
            window._lastHeight = next;
            __postWidgetMessage({_type:'height', value: next});
        };
        window._attachHeightObserver = function() {
            var r = document.getElementById('root');
            if (!r || window._heightObserver) return;
            window._heightObserver = new ResizeObserver(function() {
                window._reportHeight();
            });
            window._heightObserver.observe(r);
        };
        window._setContent = function(html) {
            var root = document.getElementById('root');
            if (!root) return;
            if (!window._morphReady || typeof morphdom !== 'function') {
                try { root.innerHTML = html; } catch (_) {}
                window._attachHeightObserver();
                setTimeout(function() {
                    window._reportHeight();
                }, 60);
                return;
            }
            var target = document.createElement('div');
            target.id = 'root';
            // Tolerate mid-stream HTML: unclosed tags or half-parsed
            // attributes must not blow up morphdom. Fall back to innerHTML
            // replacement; the next delta that closes the tag will
            // re-diff cleanly.
            try {
                target.innerHTML = html;
                morphdom(root, target, {
                    onBeforeElUpdated: function(from, to) {
                        if (from.isEqualNode(to)) return false;
                        return true;
                    },
                    onNodeAdded: function(node) {
                        if (node.nodeType === 1 && node.tagName !== 'STYLE' && node.tagName !== 'SCRIPT') {
                            node.style.animation = '_fadeIn 0.3s ease both';
                        }
                        return node;
                    }
                });
            } catch (e) {
                try { root.innerHTML = html; } catch (_) {}
            }
            window._attachHeightObserver();
            setTimeout(function() {
                window._reportHeight();
            }, 60);
        };
        window._runScripts = function() {
            document.querySelectorAll('#root script').forEach(function(old) {
                var s = document.createElement('script');
                if (old.src) { s.src = old.src; } else { s.textContent = old.textContent; }
                old.parentNode.replaceChild(s, old);
            });
            window._attachHeightObserver();
            setTimeout(function() {
                window._reportHeight();
            }, 250);
        };
        window.sendPrompt = function(text) {
            __postWidgetMessage({_type:'sendPrompt', text: text});
        };
        window.openLink = function(url) {
            __postWidgetMessage({_type:'openLink', url: url});
        };
        </script>
        <script src="https://cdn.jsdelivr.net/npm/morphdom@2.7.4/dist/morphdom-umd.min.js"
            onload="window._morphReady=true;if(window._pending){window._setContent(window._pending);window._pending=null;}__postWidgetMessage({_type:'ready'});"></script>
        </body></html>
    """.trimIndent()
}

/**
 * JS block providing the `loadAppState` / `saveAppState` bridge consumed by
 * saved-app-mode widgets. Spliced into the shell before
 * `window._morphReady = false;` (mirrors iOS's `buildAppModeShellHTML`) so
 * user widget scripts can call the bridge synchronously during first render.
 *
 * The raw state JSON is sanitized by replacing `</` with `<\/` before being
 * spliced into the inline script to prevent a stray `</script>` sequence in
 * user data from closing our tag.
 */
private fun buildAppStateInjection(appState: AppStateInjection): String {
    val escapedJson = appState.stateJson
        ?.let { org.json.JSONObject.quote(it) }
        ?.replace("</", "<\\/")
        ?: "null"
    val schema = appState.schemaVersion.toLong()
    return """
        <script>
          window._initialAppState = $escapedJson;
          window._appStateSchemaVersion = $schema;
          window.loadAppState = function() {
            try {
              if (window._initialAppState == null) return null;
              return JSON.parse(window._initialAppState);
            } catch (_) { return null; }
          };
          window.saveAppState = function(obj) {
            var payload;
            try { payload = JSON.stringify(obj); } catch (_) { return false; }
            return __postWidgetMessage({
              _type: 'saveAppState',
              value: payload,
              schema: window._appStateSchemaVersion,
            });
          };
          (function(){
            var nextId = 1;
            var pending = new Map();
            window.structuredResponse = function(req) {
              var id = 'sr-' + (nextId++);
              return new Promise(function(resolve, reject) {
                pending.set(id, { resolve: resolve, reject: reject });
                var fmt = (req && req.responseFormat) || null;
                __postWidgetMessage({
                  _type: 'structuredResponse',
                  requestId: id,
                  prompt: String((req && req.prompt) || ''),
                  responseFormat: fmt,
                });
              });
            };
            window.__resolveStructuredResponse = function(id, jsonText) {
              var p = pending.get(id); if (!p) return;
              pending.delete(id);
              try { p.resolve(JSON.parse(jsonText)); }
              catch (e) { p.reject(new Error('invalid structured response JSON: ' + (e && e.message))); }
            };
            window.__rejectStructuredResponse = function(id, message) {
              var p = pending.get(id); if (!p) return;
              pending.delete(id);
              p.reject(new Error(message || 'structuredResponse failed'));
            };
          })();
        </script>
    """.trimIndent()
}

/**
 * Escape a string so it can be embedded as a JS single-quoted literal inside
 * `evaluateJavascript("window._setContent('...'); ...")`. Matches iOS's
 * `WidgetWebView.escapeJS` character-for-character.
 */
internal fun escapeJsString(s: String): String =
    s.replace("\\", "\\\\")
        .replace("'", "\\'")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("</script>", "<\\/script>")

private fun workspaceTitle(path: String): String {
    return path
        .trimEnd('/')
        .substringAfterLast('/')
        .ifBlank { path }
}

@Composable
private fun CodeBlockSegment(
    language: String?,
    code: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
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
                        fontSize = LitterTextStyle.body.scaled,
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                    )
                }
            }
        }
    }
}

@Composable
private fun ToolCardShell(
    summary: String,
    summaryAnnotated: AnnotatedString? = null,
    accent: Color,
    status: AppOperationStatus,
    durationMs: Long? = null,
    defaultExpanded: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    var expanded by remember(summary, status) {
        mutableStateOf(defaultExpanded || status == AppOperationStatus.FAILED)
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(12.dp))
            .border(0.5.dp, LitterTheme.border, RoundedCornerShape(12.dp))
            .clickable { expanded = !expanded }
            .padding(horizontal = 12.dp, vertical = 9.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusIcon(status)
            Spacer(Modifier.width(8.dp))
            Text(
                text = summaryAnnotated ?: AnnotatedString(summary),
                color = LitterTheme.textSystem,
                fontSize = LitterTextStyle.body.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            durationMs?.takeIf { it > 0 }?.let { ms ->
                Spacer(Modifier.width(8.dp))
                DurationChip(formatDuration(ms), statusTint(status))
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = if (expanded) "▲" else "▼",
                color = accent,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Bold,
            )
        }

        if (expanded) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 6.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                content = content,
            )
        }
    }
}

private fun displayCommandText(command: String): String {
    val trimmed = command.trim()
    return if (trimmed.isEmpty()) "command" else trimmed
}

private fun collapseCommandText(command: String): String {
    val collapsed = displayCommandText(command)
        .replace(Regex("\\s+"), " ")
        .trim()
    return if (collapsed.isEmpty()) "command" else collapsed
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        color = LitterTheme.textSecondary,
        fontSize = LitterTextStyle.caption2.scaled,
        fontWeight = FontWeight.Bold,
    )
}

@Composable
private fun CodeSection(
    label: String,
    content: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(label)
        LimitedToolTextBlock(content) { display ->
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                    .padding(10.dp),
            ) {
                Text(
                    text = display,
                    color = LitterTheme.textBody,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = LitterTextStyle.body.scaled,
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                )
            }
        }
    }
}

@Composable
private fun InlineTextSection(
    label: String,
    content: String,
    tone: Color = LitterTheme.textBody,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(label)
        LimitedToolTextBlock(content) { display ->
            Text(
                text = display,
                color = tone,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.body.scaled,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                    .padding(horizontal = 10.dp, vertical = 8.dp),
            )
        }
    }
}

@Composable
private fun KeyValueSection(
    label: String,
    entries: List<Pair<String, String>>,
) {
    if (entries.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(label)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
                .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            entries.forEach { (key, value) ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "$key:",
                        color = LitterTheme.textSecondary,
                        fontSize = LitterTextStyle.body.scaled,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        LimitedToolTextBlock(value) { display ->
                            Text(
                                text = display,
                                color = LitterTheme.textSystem,
                                fontSize = LitterTextStyle.body.scaled,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ListSection(
    label: String,
    items: List<String>,
) {
    if (items.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(label)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
                .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            items.forEach { item ->
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("•", color = LitterTheme.textSecondary, fontSize = LitterTextStyle.body.scaled)
                    Column(modifier = Modifier.weight(1f)) {
                        LimitedToolTextBlock(item) { display ->
                            Text(
                                text = display,
                                color = LitterTheme.textSystem,
                                fontSize = LitterTextStyle.body.scaled,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ProgressSection(
    label: String,
    items: List<String>,
) {
    if (items.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(label)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
                .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            items.forEachIndexed { index, item ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "•",
                        color = if (index == items.lastIndex) LitterTheme.accentStrong else LitterTheme.textMuted,
                        fontSize = LitterTextStyle.body.scaled,
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        LimitedToolTextBlock(item) { display ->
                            Text(
                                text = display,
                                color = LitterTheme.textSystem,
                                fontSize = LitterTextStyle.body.scaled,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DiffSection(
    label: String,
    content: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (label.isNotEmpty()) {
            SectionLabel(label)
        }
        LimitedToolTextBlock(content) { display ->
            SyntaxHighlightedDiffBlock(
                diff = display,
                titleHint = label.ifEmpty { null },
                fontSize = LitterTextStyle.caption.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            )
        }
    }
}

@Composable
private fun LimitedToolTextBlock(
    content: String,
    previewFromTail: Boolean = false,
    body: @Composable (String) -> Unit,
) {
    val isLong = content.length > ToolCallTextPreviewLimit
    var expanded by remember(content, previewFromTail) { mutableStateOf(false) }
    val display = remember(content, expanded, previewFromTail) {
        if (isLong && !expanded) {
            if (previewFromTail) content.takeLast(ToolCallTextPreviewLimit) else content.take(ToolCallTextPreviewLimit)
        } else {
            content
        }
    }

    body(display)

    if (isLong) {
        TextButton(onClick = { expanded = !expanded }) {
            Text(
                text = if (expanded) "Show less" else "Show more",
                color = LitterTheme.accent,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

@Composable
private fun RichDynamicToolResult(
    payload: RichDynamicToolPayload,
) {
    when (payload) {
        is RichDynamicToolPayload.Servers -> {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                payload.items.forEach { item ->
                    SessionServerCard(
                        icon = {
                            Icon(
                                if (item.isLocal) Icons.Default.PhoneAndroid else Icons.Default.Dns,
                                contentDescription = null,
                                tint = LitterTheme.accent,
                                modifier = Modifier.size(18.dp),
                            )
                        },
                        title = item.name,
                        subtitle = item.hostname,
                        trailing = if (item.isConnected) "Connected" else "Offline",
                        statusDotColor = if (item.isConnected) LitterTheme.success else LitterTheme.textMuted,
                    )
                }
            }
        }
        is RichDynamicToolPayload.Sessions -> {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                payload.items.forEach { item ->
                    val subtitle = listOfNotNull(
                        item.serverName?.takeIf { it.isNotBlank() },
                        item.model?.takeIf { it.isNotBlank() },
                    ).joinToString(" \u00b7 ")
                    SessionServerCard(
                        icon = {
                            Icon(
                                Icons.Default.Chat,
                                contentDescription = null,
                                tint = LitterTheme.accent,
                                modifier = Modifier.size(18.dp),
                            )
                        },
                        title = item.title.ifBlank { "Untitled session" },
                        subtitle = subtitle,
                        trailing = null,
                        statusDotColor = null,
                    )
                }
            }
        }
    }
}

@Composable
private fun SessionServerCard(
    icon: @Composable () -> Unit,
    title: String,
    subtitle: String,
    trailing: String?,
    statusDotColor: Color?,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(14.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(32.dp)
                .background(LitterTheme.accent.copy(alpha = 0.12f), RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            icon()
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.subheadline.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle.isNotBlank()) {
                Text(
                    text = subtitle,
                    color = LitterTheme.textMuted,
                    fontSize = LitterTextStyle.caption.scaled,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (statusDotColor != null || trailing != null) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                statusDotColor?.let { dotColor ->
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(dotColor),
                    )
                }
                trailing?.let {
                    Text(
                        text = it,
                        color = LitterTheme.textMuted,
                        fontSize = LitterTextStyle.caption.scaled,
                    )
                }
            }
        }
    }
}

private sealed class RichDynamicToolPayload {
    data class Servers(val items: List<ServerItem>) : RichDynamicToolPayload()
    data class Sessions(val items: List<SessionItem>) : RichDynamicToolPayload()
}

private data class ServerItem(
    val name: String,
    val hostname: String,
    val isConnected: Boolean,
    val isLocal: Boolean,
)

private data class SessionItem(
    val title: String,
    val serverName: String?,
    val model: String?,
)

private fun decodeRichDynamicToolPayload(
    tool: String,
    contentSummary: String?,
): RichDynamicToolPayload? {
    if (contentSummary.isNullOrBlank()) return null
    if (tool != "list_servers" && tool != "list_sessions") return null
    return try {
        val root = JSONObject(contentSummary)
        when (root.optString("type")) {
            "servers" -> {
                val items = root.optJSONArray("items") ?: JSONArray()
                RichDynamicToolPayload.Servers(
                    List(items.length()) { index ->
                        val item = items.optJSONObject(index) ?: JSONObject()
                        ServerItem(
                            name = item.optString("name"),
                            hostname = item.optString("hostname"),
                            isConnected = item.optBoolean("isConnected"),
                            isLocal = item.optBoolean("isLocal"),
                        )
                    },
                )
            }
            "sessions" -> {
                val items = root.optJSONArray("items") ?: JSONArray()
                RichDynamicToolPayload.Sessions(
                    List(items.length()) { index ->
                        val item = items.optJSONObject(index) ?: JSONObject()
                        SessionItem(
                            title = item.optString("preview"),
                            serverName = item.optString("serverName").takeIf { it.isNotBlank() },
                            model = item.optString("modelProvider").ifBlank {
                                item.optString("model_provider")
                            }.takeIf { it.isNotBlank() },
                        )
                    },
                )
            }
            else -> null
        }
    } catch (_: Exception) {
        null
    }
}

// ── Shared Helpers ───────────────────────────────────────────────────────────

@Composable
internal fun StatusIcon(status: AppOperationStatus) {
    when (status) {
        AppOperationStatus.IN_PROGRESS -> {
            CircularProgressIndicator(
                modifier = Modifier.size(14.dp),
                strokeWidth = 2.dp,
                color = LitterTheme.accent,
            )
        }
        AppOperationStatus.COMPLETED -> {
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = "Completed",
                tint = LitterTheme.success,
                modifier = Modifier.size(14.dp),
            )
        }
        AppOperationStatus.FAILED -> {
            Icon(
                Icons.Default.Error,
                contentDescription = "Failed",
                tint = LitterTheme.danger,
                modifier = Modifier.size(14.dp),
            )
        }
        else -> {
            Icon(
                Icons.Default.HourglassEmpty,
                contentDescription = "Unknown",
                tint = LitterTheme.textMuted,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

private fun statusTint(status: AppOperationStatus): Color {
    return when (status) {
        AppOperationStatus.COMPLETED -> LitterTheme.success
        AppOperationStatus.IN_PROGRESS -> LitterTheme.warning
        AppOperationStatus.FAILED -> LitterTheme.danger
        else -> LitterTheme.textMuted
    }
}

@Composable
private fun DurationChip(text: String, tint: Color) {
    Box(
        modifier = Modifier
            .background(tint.copy(alpha = 0.10f), RoundedCornerShape(999.dp))
            .border(0.5.dp, tint.copy(alpha = 0.22f), RoundedCornerShape(999.dp))
            .padding(horizontal = 7.dp, vertical = 2.dp),
    ) {
        Text(
            text = text,
            color = tint,
            fontSize = LitterTextStyle.caption2.scaled,
        )
    }
}

private fun formatDuration(ms: Long): String {
    return when {
        ms < 1000 -> "${ms}ms"
        ms < 60_000 -> "%.1fs".format(ms / 1000.0)
        else -> "${ms / 60_000}m ${(ms % 60_000) / 1000}s"
    }
}
