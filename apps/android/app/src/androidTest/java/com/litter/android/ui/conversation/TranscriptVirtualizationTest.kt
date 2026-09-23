package com.litter.android.ui.conversation

import android.util.Log
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import uniffi.codex_mobile_client.HydratedAssistantMessageData
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.HydratedUserMessageData

@RunWith(AndroidJUnit4::class)
class TranscriptVirtualizationTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun largeTurnVirtualizesRowsAndKeepsHistoryAfterFollowUp() {
        val collapseState = TranscriptPresentationState()
        val history = listOf(user("first", "t1")) + (1..500).map { index ->
            HydratedConversationItem(
                "answer-$index",
                HydratedConversationItemContent.Assistant(HydratedAssistantMessageData("answer $index", null, null, null)),
                "t1", null, null, false,
            )
        }
        val rows = mutableStateOf(buildTranscriptRows(buildTranscriptTurns(history, false, 1), collapseState, emptySet()))
        val mounted = mutableSetOf<String>()
        compose.setContent {
            LazyColumn(Modifier.height(400.dp).testTag("transcript"), state = rememberLazyListState()) {
                transcriptRows(rows.value) { row ->
                    DisposableEffect(row.key) {
                        mounted += row.key
                        onDispose { mounted -= row.key }
                    }
                    Text(row.key, Modifier.height(48.dp))
                }
                item(key = "bottom") { Text("bottom", Modifier.height(48.dp)) }
            }
        }
        compose.runOnIdle {
            Log.i("TranscriptVirtualizationTest", "Initial mounted rows: ${mounted.size} / ${rows.value.size}")
            assertTrue("Long turn must not compose all 501 messages", mounted.size in 1..30)
        }
        compose.onNodeWithTag("transcript").performScrollToIndex(rows.value.size)
        compose.onNodeWithText("bottom").assertIsDisplayed()
        compose.runOnIdle {
            assertTrue("Only viewport rows should stay mounted", mounted.size < 30)
            rows.value = buildTranscriptRows(
                buildTranscriptTurns(history + user("follow-up", "t2"), true, 1), collapseState, emptySet(),
            )
            assertTrue(rows.value.none { it is TranscriptRow.Collapsed })
        }
        compose.onNodeWithTag("transcript").performScrollToIndex(rows.value.size)
        compose.onNodeWithText("bottom").assertIsDisplayed()
        compose.onNodeWithTag("transcript").performScrollToIndex(0)
        compose.onNodeWithText("item-first").assertIsDisplayed()
        compose.onNodeWithText("item-answer-1").assertIsDisplayed()
        compose.runOnIdle {
            Log.i("TranscriptVirtualizationTest", "Follow-up mounted rows: ${mounted.size} / ${rows.value.size}")
            assertTrue(mounted.size < 30)
        }
    }

    private fun user(id: String, turnId: String) = HydratedConversationItem(
        id, HydratedConversationItemContent.User(HydratedUserMessageData(id, emptyList())),
        turnId, null, null, true,
    )
}
