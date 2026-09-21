package com.litter.android.ui.settings

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.litter.android.MainActivity
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HarnessSettingsNavigationTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun settingsMenuReachesHarnessesAndReturns() {
        compose.waitUntil(15_000) {
            compose.onAllNodesWithContentDescription("Settings").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.onNodeWithTag("settings.content").performScrollToNode(hasText("Harnesses"))
        compose.onNodeWithText("Harnesses").performClick()
        compose.onNodeWithText("Harnesses").assertIsDisplayed()
        compose.onNodeWithText("Back").performClick()
        compose.onNodeWithTag("settings.content").assertIsDisplayed()
    }
}
