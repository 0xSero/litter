package com.litter.android.ui.settings

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.codex_mobile_client.RuntimeSettingDescriptor
import uniffi.codex_mobile_client.RuntimeSettingValueKind

@RunWith(AndroidJUnit4::class)
class HarnessSettingsEditorTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun unsetChoiceSavesAJsonStringAndRendersReadback() {
        showEditor(setting("theme", "null", RuntimeSettingValueKind.JSON, listOf("dark", "light")))
        compose.onNodeWithText("dark").performScrollTo().performClick()
        compose.onNodeWithText("Save").performClick()
        compose.onNodeWithText("Saved: \"dark\"").assertIsDisplayed()
    }

    @Test
    fun booleanToggleSavesAndRendersReadback() {
        showEditor(setting("quietStartup", "false", RuntimeSettingValueKind.BOOLEAN))
        compose.onNode(isToggleable()).performClick()
        compose.onNodeWithText("Save").performClick()
        compose.onNodeWithText("Saved: true").assertIsDisplayed()
    }

    @Test
    fun managedSettingShowsReasonAndDisablesEditing() {
        showEditor(setting("managedPolicy", "true", RuntimeSettingValueKind.BOOLEAN, writable = false))
        compose.onNodeWithText("Managed by administrator").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Save").assertIsNotEnabled()
        compose.onNode(isToggleable()).assertIsNotEnabled()
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Cancelled").assertIsDisplayed()
    }

    @Test
    fun unsetStringStartsBlankAndSavesOnlyAfterEditing() {
        showEditor(setting("name", "null", RuntimeSettingValueKind.STRING))
        compose.onNodeWithText("Unset").assertIsDisplayed()
        compose.onNodeWithText("Save").assertIsNotEnabled()
        compose.onNode(hasSetTextAction()).assert(SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")))
        compose.onNode(hasSetTextAction()).performTextInput("chosen")
        compose.onNodeWithText("Save").performClick()
        compose.onNodeWithText("Saved: \"chosen\"").assertIsDisplayed()
    }

    @Test
    fun unsetBooleanCanExplicitlyChooseFalse() {
        showEditor(setting("flag", "null", RuntimeSettingValueKind.BOOLEAN))
        compose.onNodeWithText("Unset").assertIsDisplayed()
        compose.onNodeWithText("Save").assertIsNotEnabled()
        compose.onNodeWithText("Disabled").performClick()
        compose.onNodeWithText("Selected: Disabled").assertIsDisplayed()
        compose.onNodeWithText("Save").performClick()
        compose.onNodeWithText("Saved: false").assertIsDisplayed()
    }

    private fun showEditor(setting: RuntimeSettingDescriptor) {
        compose.setContent {
            MaterialTheme {
                var closed by remember { mutableStateOf(false) }
                var saved by remember { mutableStateOf<String?>(null) }
                if (closed) Text(saved?.let { "Saved: $it" } ?: "Cancelled")
                else RuntimeSettingEditor(setting, onDismiss = { closed = true }) { value -> saved = value }
            }
        }
    }

    private fun setting(key: String, value: String, kind: RuntimeSettingValueKind,
        choices: List<String> = emptyList(), writable: Boolean = true) = RuntimeSettingDescriptor(
        key = key, label = key, valueJson = value, valueKind = kind, choices = choices,
        scope = if (writable) "user" else "managed", source = "Instrumentation fixture",
        writable = writable, readOnlyReason = if (writable) null else "Managed by administrator",
    )
}
