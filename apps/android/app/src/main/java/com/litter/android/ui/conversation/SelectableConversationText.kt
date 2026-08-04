package com.litter.android.ui.conversation

import android.util.TypedValue
import android.text.method.LinkMovementMethod
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.widget.TextView
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.litter.android.state.AppModel
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterThemeManager
import com.litter.android.ui.LocalTextScale
import io.noties.markwon.AbstractMarkwonPlugin
import io.noties.markwon.Markwon
import io.noties.markwon.core.MarkwonTheme
import io.noties.markwon.ext.latex.JLatexMathPlugin
import io.noties.markwon.ext.tables.TablePlugin
import io.noties.markwon.inlineparser.MarkwonInlineParserPlugin
import io.noties.markwon.syntax.SyntaxHighlightPlugin
import io.noties.prism4j.Prism4j
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@Composable
internal fun SelectableConversationText(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    SelectionContainer(modifier = modifier) {
        content()
    }
}

@Composable
internal fun SelectableMarkdownText(
    text: String,
    modifier: Modifier = Modifier,
    bodySize: Float = LitterTextStyle.body,
    usePhysicalDpTextSize: Boolean = false,
    selectable: Boolean = true,
    onTextViewReady: ((TextView) -> Unit)? = null,
) {
    val context = LocalContext.current
    val textScale = LocalTextScale.current
    val resolvedTextSize = bodySize * textScale
    val textColor = LitterTheme.textBody.toArgb()
    val useMono = LitterThemeManager.monoFontEnabled
    val typeface = remember(context, useMono) {
        if (useMono) {
            runCatching {
                androidx.core.content.res.ResourcesCompat.getFont(
                    context,
                    com.sigkitten.litter.android.R.font.berkeley_mono_regular,
                )
            }.getOrNull() ?: android.graphics.Typeface.MONOSPACE
        } else {
            android.graphics.Typeface.DEFAULT
        }
    }
    val markdownTextSizePx = remember(context, resolvedTextSize, usePhysicalDpTextSize) {
        resolvedTextSize.toTextSizePx(context, usePhysicalDpTextSize)
    }
    val markwon = rememberConversationMarkwon(
        context = context,
        typeface = typeface,
        markdownTextSizePx = markdownTextSizePx,
        textColor = textColor,
    )
    val markdown = remember(text) { normalizeMathMarkdown(text) }

    AndroidView(
        factory = { ctx ->
            TextView(ctx).apply {
                configureSelectableMarkdownTextView(
                    textView = this,
                    textColor = textColor,
                    linkColor = LitterTheme.accent.toArgb(),
                    textSize = resolvedTextSize,
                    typeface = typeface,
                    usePhysicalDpTextSize = usePhysicalDpTextSize,
                    selectable = selectable,
                )
                onTextViewReady?.invoke(this)
            }
        },
        update = { tv ->
            configureSelectableMarkdownTextView(
                textView = tv,
                textColor = textColor,
                linkColor = LitterTheme.accent.toArgb(),
                textSize = resolvedTextSize,
                typeface = typeface,
                usePhysicalDpTextSize = usePhysicalDpTextSize,
                selectable = selectable,
            )
            val renderTag = MarkdownRenderTag(
                markdown = markdown,
                textColor = textColor,
                textSizePx = markdownTextSizePx,
                typeface = typeface,
            )
            if (tv.tag != renderTag) {
                tv.tag = renderTag
                markwon.setMarkdown(tv, markdown)
            }
        },
        modifier = modifier,
    )
}

private data class MarkdownRenderTag(
    val markdown: String,
    val textColor: Int,
    val textSizePx: Float,
    val typeface: android.graphics.Typeface?,
)

internal fun configureSelectableMarkdownTextView(
    textView: TextView,
    textColor: Int,
    linkColor: Int,
    textSize: Float,
    typeface: android.graphics.Typeface? = null,
    usePhysicalDpTextSize: Boolean = false,
    selectable: Boolean = true,
) {
    textView.setTextColor(textColor)
    textView.typeface = typeface
    textView.includeFontPadding = false
    if (usePhysicalDpTextSize) {
        textView.setTextSize(TypedValue.COMPLEX_UNIT_DIP, textSize)
    } else {
        textView.textSize = textSize
    }
    textView.linksClickable = true
    textView.movementMethod = LinkMovementMethod.getInstance()
    textView.setLinkTextColor(linkColor)
    textView.setTextIsSelectable(selectable)
    textView.customSelectionActionModeCallback = if (selectable) {
        RunInTerminalSelectionMenu(textView)
    } else {
        null
    }
}

/**
 * Adds a "Run in Terminal" item to the text-selection ActionMode of the
 * markwon-rendered conversation text. Available only when the Rust store has
 * an active terminal session.
 */
private class RunInTerminalSelectionMenu(
    private val textView: TextView,
) : ActionMode.Callback {
    override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
        if (hasActiveTerminalSession()) {
            menu.add(Menu.NONE, MENU_ID_RUN_IN_TERMINAL, Menu.CATEGORY_SECONDARY, "Run in Terminal")
        }
        return true
    }

    override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean {
        val existing = menu.findItem(MENU_ID_RUN_IN_TERMINAL)
        val hasSession = hasActiveTerminalSession()
        if (hasSession && existing == null) {
            menu.add(Menu.NONE, MENU_ID_RUN_IN_TERMINAL, Menu.CATEGORY_SECONDARY, "Run in Terminal")
            return true
        }
        if (!hasSession && existing != null) {
            menu.removeItem(MENU_ID_RUN_IN_TERMINAL)
            return true
        }
        return false
    }

    override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
        if (item.itemId != MENU_ID_RUN_IN_TERMINAL) return false
        val start = textView.selectionStart.coerceAtLeast(0)
        val end = textView.selectionEnd.coerceAtMost(textView.text.length)
        if (start >= end) {
            mode.finish()
            return true
        }
        val selected = textView.text.subSequence(start, end).toString()
        val bytes = selected.toByteArray(Charsets.UTF_8)
        CoroutineScope(Dispatchers.Main.immediate).launch {
            runCatching {
                AppModel.shared.store.writeToActiveTerminal(bytes)
            }
        }
        mode.finish()
        return true
    }

    override fun onDestroyActionMode(mode: ActionMode) {}

    companion object {
        private const val MENU_ID_RUN_IN_TERMINAL = 0x6c697474 // 'litt'

        private fun hasActiveTerminalSession(): Boolean =
            AppModel.shared.store.activeTerminalId() != null
    }
}

@Composable
private fun rememberConversationMarkwon(
    context: android.content.Context,
    typeface: android.graphics.Typeface?,
    markdownTextSizePx: Float,
    textColor: Int,
): Markwon = remember(context, typeface, markdownTextSizePx, textColor) {
    try {
        val prism4j = Prism4j(com.litter.android.ui.Prism4jGrammarLocator())
        Markwon.builder(context)
            .usePlugin(object : AbstractMarkwonPlugin() {
                override fun configureTheme(builder: MarkwonTheme.Builder) {
                    typeface?.let { builder.codeTypeface(it) }
                }
            })
            .usePlugin(
                SyntaxHighlightPlugin.create(
                    prism4j,
                    io.noties.markwon.syntax.Prism4jThemeDarkula.create(),
                ),
            )
            .usePlugin(TablePlugin.create(context))
            .usePlugin(MarkwonInlineParserPlugin.create())
            .usePlugin(
                JLatexMathPlugin.create(markdownTextSizePx, markdownTextSizePx * 1.12f) { builder ->
                    builder.inlinesEnabled(true)
                    builder.blocksEnabled(true)
                    builder.theme().textColor(textColor)
                },
            )
            .build()
    } catch (_: Exception) {
        Markwon.create(context)
    }
}

private fun Float.toTextSizePx(
    context: android.content.Context,
    usePhysicalDpTextSize: Boolean,
): Float {
    val unit = if (usePhysicalDpTextSize) {
        TypedValue.COMPLEX_UNIT_DIP
    } else {
        TypedValue.COMPLEX_UNIT_SP
    }
    return TypedValue.applyDimension(unit, this, context.resources.displayMetrics)
}
