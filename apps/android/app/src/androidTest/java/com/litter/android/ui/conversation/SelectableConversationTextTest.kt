package com.litter.android.ui.conversation

import android.text.method.LinkMovementMethod
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SelectableConversationTextTest {

    @Test
    fun configureSelectableMarkdownTextView_enablesSelectionAndLinks() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val textView = TextView(context)

        configureSelectableMarkdownTextView(
            textView = textView,
            textColor = 0xFFFFFFFF.toInt(),
            linkColor = 0xFF00FF9C.toInt(),
            textSize = 14f,
        )

        assertTrue(textView.isTextSelectable)
        assertTrue(textView.linksClickable)
        assertTrue(textView.movementMethod is LinkMovementMethod)
    }
}
