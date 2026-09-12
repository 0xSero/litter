package com.litter.android.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.text.ClickableText
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DesktopMac
import androidx.compose.material.icons.filled.Extension
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTheme
import uniffi.codex_mobile_client.TitleSegment
import uniffi.codex_mobile_client.parsePluginRefs

/**
 * Drop-in replacement for `Text` that applies inline formatting such as
 * plugin-reference pills (`[@Name](plugin://plugin-name@marketplace)`).
 *
 * Parsing lives in shared Rust so iOS/Android stay in sync. Falls back to
 * plain `Text` when there's nothing to format. When [maxLines] == 1, renders
 * a single-line Row with ellipsis truncation on text runs; otherwise wraps
 * via FlowRow.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FormattedText(
    text: String,
    color: Color,
    fontSize: TextUnit,
    modifier: Modifier = Modifier,
    maxLines: Int = Int.MAX_VALUE,
) {
    val segments = remember(text) { parsePluginRefs(text) }

    // Fast path: no pills.
    if (segments.size == 1 && segments[0] is TitleSegment.Text) {
        LinkifiedText(
            text = (segments[0] as TitleSegment.Text).`text`,
            color = color,
            fontSize = fontSize,
            maxLines = maxLines,
            modifier = modifier,
        )
        return
    }

    if (maxLines == 1) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(0.dp),
            modifier = modifier,
        ) {
            segments.forEach { segment ->
                when (segment) {
                    is TitleSegment.Text -> LinkifiedText(
                        text = segment.`text`,
                        color = color,
                        fontSize = fontSize,
                        maxLines = 1,
                    )
                    is TitleSegment.PluginRef -> PluginPill(
                        displayName = segment.`displayName`,
                        pluginName = segment.`pluginName`,
                        fontSize = fontSize,
                    )
                }
            }
        }
    } else {
        FlowRow(
            modifier = modifier,
            horizontalArrangement = Arrangement.spacedBy(0.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            segments.forEach { segment ->
                when (segment) {
                    is TitleSegment.Text -> LinkifiedText(
                        text = segment.`text`,
                        color = color,
                        fontSize = fontSize,
                    )
                    is TitleSegment.PluginRef -> PluginPill(
                        displayName = segment.`displayName`,
                        pluginName = segment.`pluginName`,
                        fontSize = fontSize,
                    )
                }
            }
        }
    }
}

private const val WebLinkAnnotation = "litter-web-link"
private val WebLinkRegex = Regex("""https?://[^\s<>]+""", RegexOption.IGNORE_CASE)
private val WebLinkTrailingPunctuation = setOf('.', ',', ';', ':', '!', '?', ']', '}')

@Composable
private fun LinkifiedText(
    text: String,
    color: Color,
    fontSize: TextUnit,
    modifier: Modifier = Modifier,
    maxLines: Int = Int.MAX_VALUE,
) {
    val uriHandler = LocalUriHandler.current
    val linkColor = LitterTheme.accent
    val annotated = remember(text, linkColor) {
        linkifiedAnnotatedString(text, linkColor)
    }
    val hasLinks = WebLinkRegex.containsMatchIn(text)
    // Only attach link tap handling when the text actually contains links.
    // ClickableText consumes taps across the whole span to detect link hits,
    // which would otherwise swallow the parent row's click when a session
    // title has no links at all.
    if (!hasLinks) {
        Text(
            text = annotated,
            style = TextStyle(color = color, fontSize = fontSize),
            maxLines = maxLines,
            overflow = TextOverflow.Ellipsis,
            modifier = modifier,
        )
        return
    }
    ClickableText(
        text = annotated,
        style = TextStyle(color = color, fontSize = fontSize),
        maxLines = maxLines,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier,
        onClick = { offset ->
            annotated.getStringAnnotations(WebLinkAnnotation, offset, offset)
                .firstOrNull()
                ?.item
                ?.let { url -> runCatching { uriHandler.openUri(url) } }
        },
    )
}

private fun linkifiedAnnotatedString(text: String, linkColor: Color): AnnotatedString {
    val matches = WebLinkRegex.findAll(text).mapNotNull { match ->
        var endExclusive = match.range.last + 1
        while (endExclusive > match.range.first && text[endExclusive - 1] in WebLinkTrailingPunctuation) {
            endExclusive -= 1
        }
        if (endExclusive == match.range.first) null else match.range.first until endExclusive
    }.toList()
    if (matches.isEmpty()) return AnnotatedString(text)

    return buildAnnotatedString {
        var cursor = 0
        matches.forEach { range ->
            append(text.substring(cursor, range.first))
            val url = text.substring(range)
            pushStringAnnotation(WebLinkAnnotation, url)
            withStyle(
                SpanStyle(
                    color = linkColor,
                    textDecoration = TextDecoration.None,
                ),
            ) {
                append(url)
            }
            pop()
            cursor = range.last + 1
        }
        append(text.substring(cursor))
    }
}

@Composable
private fun PluginPill(
    displayName: String,
    pluginName: String,
    fontSize: TextUnit,
) {
    val icon: ImageVector = when (pluginName) {
        "computer-use" -> Icons.Default.DesktopMac
        else -> Icons.Default.Extension
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .background(
                color = LitterTheme.accent.copy(alpha = 0.15f),
                shape = RoundedCornerShape(6.dp),
            )
            .padding(horizontal = 7.dp, vertical = 2.dp),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = LitterTheme.accent,
            modifier = Modifier.width(12.dp),
        )
        Spacer(Modifier.width(4.dp))
        Text(
            text = displayName,
            color = LitterTheme.accent,
            fontSize = fontSize,
            maxLines = 1,
        )
    }
}
