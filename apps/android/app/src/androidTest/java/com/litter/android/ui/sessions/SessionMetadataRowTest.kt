package com.litter.android.ui.sessions

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionMetadataRowTest {

    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun timestampRemainsWholeAtNarrowWidthAndIncreasedFontScale() {
        composeTestRule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density = density.density, fontScale = 2f),
            ) {
                Box(modifier = Modifier.width(180.dp)) {
                    SessionMetadataRow(
                        modelLabel = "a-very-long-provider-and-model-name-that-must-yield",
                        agentLabel = "a-very-long-runtime-label-that-must-yield",
                        relativeTime = "just now",
                    )
                }
            }
        }

        val timestamp = composeTestRule.onNodeWithText("just now")
        timestamp.assertWidthIsAtLeast(48.dp)

        val textLayouts = mutableListOf<TextLayoutResult>()
        timestamp.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { action ->
            assertTrue(action(textLayouts))
        }

        val layout = textLayouts.single()
        assertEquals(1, layout.lineCount)
        assertFalse(layout.didOverflowWidth)
        assertFalse(layout.didOverflowHeight)
        assertFalse(layout.isLineEllipsized(0))
    }
}
