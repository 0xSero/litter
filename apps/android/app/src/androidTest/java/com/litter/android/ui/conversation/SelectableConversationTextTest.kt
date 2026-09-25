package com.litter.android.ui.conversation

import android.os.SystemClock
import android.text.Selection
import android.text.Spannable
import android.text.SpannableString
import android.text.Spanned
import android.text.method.LinkMovementMethod
import android.text.style.ClickableSpan
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SelectableConversationTextTest {

    @Test
    fun configureSelectableMarkdownTextView_enablesSelectionAndLinks() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val textView = TextView(instrumentation.targetContext)
            textView.layoutParams = ViewGroup.LayoutParams(1200, ViewGroup.LayoutParams.WRAP_CONTENT)
            var linkClicks = 0
            val content = SpannableString("plain link text")
            val linkStart = 6
            val linkEnd = 10
            content.setSpan(object : ClickableSpan() {
                override fun onClick(widget: View) {
                    assertSame(textView, widget)
                    linkClicks++
                }
            }, linkStart, linkEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            textView.setText(content, TextView.BufferType.SPANNABLE)

            // Android replaces movement/buffer state when selection changes.
            // Reconfigure the same view and text, as AndroidView.update does.
            for ((index, selectable) in listOf(true, false, true).withIndex()) {
                configureSelectableMarkdownTextView(
                    textView = textView,
                    textColor = 0xFFFFFFFF.toInt(),
                    linkColor = 0xFF00FF9C.toInt(),
                    textSize = 14f,
                    selectable = selectable,
                )

                assertEquals(selectable, textView.isTextSelectable)
                assertTrue(textView.linksClickable)
                assertTrue(textView.movementMethod is LinkMovementMethod)
                if (selectable) {
                    assertNotNull(textView.customSelectionActionModeCallback)
                    assertTrue(textView.movementMethod.canSelectArbitrarily())
                    val buffer = textView.text as Spannable
                    // Select ordinary text, independently of clickable-span boundaries.
                    Selection.setSelection(buffer, 1, 4)
                    assertEquals(1, textView.selectionStart)
                    assertEquals(4, textView.selectionEnd)
                    assertEquals("lai", buffer.subSequence(1, 4).toString())
                    Selection.removeSelection(buffer)
                } else {
                    assertNull(textView.customSelectionActionModeCallback)
                }

                textView.measure(
                    View.MeasureSpec.makeMeasureSpec(1200, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
                )
                textView.layout(0, 0, textView.measuredWidth, textView.measuredHeight)
                tapLink(textView, linkStart, linkEnd)
                assertEquals("link must survive selectable=$selectable", index + 1, linkClicks)
            }
        }
    }

    private fun tapLink(textView: TextView, start: Int, end: Int) {
        val layout = textView.layout
        val line = layout.getLineForOffset(start)
        assertEquals(line, layout.getLineForOffset(end))
        val x = (layout.getPrimaryHorizontal(start) + layout.getPrimaryHorizontal(end)) / 2f +
            textView.totalPaddingLeft - textView.scrollX
        val y = (layout.getLineTop(line) + layout.getLineBottom(line)) / 2f +
            textView.totalPaddingTop - textView.scrollY
        val downTime = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, x, y, 0)
            try {
                textView.dispatchTouchEvent(event)
            } finally {
                event.recycle()
            }
        }
    }
}
