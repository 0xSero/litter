package com.litter.android.ui.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.runtime.collectAsState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.OutlinedTextField
import com.litter.android.ui.BerkeleyMono
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppStore
import uniffi.codex_mobile_client.ApprovalDecisionValue
import uniffi.codex_mobile_client.ApprovalKind
import uniffi.codex_mobile_client.PendingApproval
import uniffi.codex_mobile_client.PendingUserInputAnswer
import uniffi.codex_mobile_client.PendingUserInputRequest

/**
 * Full-screen overlay for pending approvals and user input requests.
 * Reads typed [PendingApproval] from Rust snapshot — no parsing needed.
 */
@Composable
fun ApprovalOverlay(
    approvals: List<PendingApproval>,
    userInputs: List<PendingUserInputRequest>,
    appStore: AppStore,
) {
    val scope = rememberCoroutineScope()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.7f))
            .clickable(enabled = false) { /* block interaction */ },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth(0.9f)
                .fillMaxHeight(0.85f)
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            for (approval in approvals) {
                ApprovalCard(
                    approval = approval,
                    onDecision = { decision ->
                        scope.launch {
                            appStore.respondToApproval(approval.id, decision)
                        }
                    },
                )
            }

            for (input in userInputs) {
                UserInputCard(
                    request = input,
                    onSubmit = { answers ->
                        scope.launch {
                            appStore.respondToUserInput(input.id, answers)
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun ApprovalCard(
    approval: PendingApproval,
    onDecision: (ApprovalDecisionValue) -> Unit,
) {
    val appModel = com.litter.android.ui.LocalAppModel.current
    val snap = appModel.snapshot.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    val isLocal = snap.value?.servers?.firstOrNull { it.serverId == approval.serverId }?.isLocal == true
    val title = when (approval.kind) {
        ApprovalKind.COMMAND -> "Run command?"
        ApprovalKind.FILE_CHANGE -> "File change?"
        ApprovalKind.PERMISSIONS -> "Grant permission?"
        ApprovalKind.MCP_ELICITATION -> "Tool request"
    }

    // Bare layout (no card background) to match iOS ConversationView prompt.
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = title,
            color = LitterTheme.textPrimary,
            fontSize = 16f.scaled,
        )

        // Command text — capped + scrollable so a long command can't push the
        // action buttons off-screen (issue #92).
        approval.command?.let { cmd ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 220.dp)
                    .background(LitterTheme.codeBackground, RoundedCornerShape(6.dp))
                    .verticalScroll(rememberScrollState())
                    .padding(8.dp),
            ) {
                Text(
                    text = cmd,
                    color = LitterTheme.accent,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = LitterTextStyle.code.scaled,
                )
            }
        }

        // CWD
        approval.cwd?.let { cwd ->
            Text(
                text = "in " + com.litter.android.state.PathDisplay.display(cwd, isLocal, context),
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption.scaled,
            )
        }

        // Path (for file changes)
        approval.path?.let { path ->
            Text(
                text = com.litter.android.state.PathDisplay.display(path, isLocal, context),
                color = LitterTheme.textSecondary,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.caption.scaled,
            )
        }

        // Buttons
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            OutlinedButton(
                onClick = { onDecision(ApprovalDecisionValue.DECLINE) },
                modifier = Modifier.weight(1f),
            ) {
                Text("Deny")
            }
            OutlinedButton(
                onClick = { onDecision(ApprovalDecisionValue.ACCEPT_FOR_SESSION) },
                modifier = Modifier.weight(1f),
            ) {
                Text("Allow session")
            }
            Button(
                onClick = { onDecision(ApprovalDecisionValue.ACCEPT) },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(
                    containerColor = LitterTheme.accent,
                    contentColor = Color.Black,
                ),
            ) {
                Text("Allow")
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun UserInputCard(
    request: PendingUserInputRequest,
    onSubmit: (List<PendingUserInputAnswer>) -> Unit,
) {
    val answers = remember { mutableMapOf<String, String>() }

    // Bare layout (no card background) to match iOS ConversationView prompt.
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Requester badge
        val requester = buildString {
            request.requesterAgentNickname?.let { append(it) }
            request.requesterAgentRole?.let {
                if (isNotEmpty()) append(" ")
                append("[$it]")
            }
        }
        if (requester.isNotBlank()) {
            Text(
                text = requester,
                color = LitterTheme.accent,
                fontSize = LitterTextStyle.caption2.scaled,
            )
        }

        for (question in request.questions) {
            Text(
                text = question.question,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.body.scaled,
            )

            if (question.options.isNotEmpty()) {
                // FlowRow so long option labels wrap to a new line instead of
                // crushing a short option into a narrow column with character-
                // by-character text wrapping.
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    for (option in question.options) {
                        val isSelected = answers[question.id] == option.label
                        Text(
                            text = option.label,
                            color = if (isSelected) Color.Black else LitterTheme.textPrimary,
                            fontSize = LitterTextStyle.caption.scaled,
                            modifier = Modifier
                                .background(
                                    if (isSelected) LitterTheme.accent else LitterTheme.codeBackground,
                                    RoundedCornerShape(999.dp),
                                )
                                .clickable { answers[question.id] = option.label }
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                        )
                    }
                }
            } else {
                // Free text input
                var text by remember { mutableStateOf("") }
                OutlinedTextField(
                    value = text,
                    onValueChange = {
                        text = it
                        answers[question.id] = it
                    },
                    label = { Text(question.header ?: "Answer") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        Button(
            onClick = {
                val answerList = request.questions.map { q ->
                    PendingUserInputAnswer(
                        questionId = q.id,
                        answers = listOfNotNull(answers[q.id]),
                    )
                }
                onSubmit(answerList)
            },
            colors = ButtonDefaults.buttonColors(
                containerColor = LitterTheme.accent,
                contentColor = Color.Black,
            ),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Submit")
        }
    }
}
