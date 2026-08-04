package com.litter.android.state

import uniffi.codex_mobile_client.AppAskForApproval
import uniffi.codex_mobile_client.AppForkThreadFromMessageRequest
import uniffi.codex_mobile_client.AppForkThreadRequest
import uniffi.codex_mobile_client.AppResumeThreadRequest
import uniffi.codex_mobile_client.AppDynamicToolSpec
import uniffi.codex_mobile_client.AppStartThreadRequest
import uniffi.codex_mobile_client.AppStartTurnRequest
import com.litter.android.ui.common.AgentRuntimeKind
import uniffi.codex_mobile_client.ReasoningEffort
import uniffi.codex_mobile_client.AppSandboxMode
import uniffi.codex_mobile_client.AppSandboxPolicy
import uniffi.codex_mobile_client.ServiceTier
import uniffi.codex_mobile_client.AppUserInput
import java.util.Base64

data class ComposerImageAttachment(
    val data: ByteArray,
    val mimeType: String,
) {
    val dataUri: String
        get() = "data:$mimeType;base64,${Base64.getEncoder().encodeToString(data)}"

    fun toUserInput(): AppUserInput.Image = AppUserInput.Image(url = dataUri)
}

data class ComposerFileAttachment(
    val label: String,
    val path: String,
)

/**
 * UI-facing config for creating or resuming threads.
 * Converts to mobile-owned Rust request types.
 */
data class AppThreadLaunchConfig(
    val agentRuntimeKind: AgentRuntimeKind? = null,
    val model: String? = null,
    val approvalPolicy: AppAskForApproval? = null,
    val sandboxMode: AppSandboxMode? = null,
    val developerInstructions: String? = null,
    val persistHistory: Boolean = true,
) {
    fun toAppStartThreadRequest(
        cwd: String,
        dynamicTools: List<AppDynamicToolSpec>? = null,
    ): AppStartThreadRequest = AppStartThreadRequest(
        agentRuntimeKind = agentRuntimeKind,
        model = model,
        cwd = cwd,
        approvalPolicy = approvalPolicy,
        sandbox = sandboxMode,
        developerInstructions = developerInstructions,
        persistExtendedHistory = persistHistory,
        dynamicTools = dynamicTools,
    )

    fun toAppResumeThreadRequest(threadId: String, cwd: String? = null): AppResumeThreadRequest =
        AppResumeThreadRequest(
            threadId = threadId,
            model = model,
            cwd = cwd,
            approvalPolicy = approvalPolicy,
            sandbox = sandboxMode,
            developerInstructions = developerInstructions,
            persistExtendedHistory = persistHistory,
        )

    fun toAppForkThreadRequest(sourceThreadId: String, cwd: String? = null): AppForkThreadRequest =
        AppForkThreadRequest(
            threadId = sourceThreadId,
            model = model,
            cwd = cwd,
            approvalPolicy = approvalPolicy,
            sandbox = sandboxMode,
            developerInstructions = developerInstructions,
            persistExtendedHistory = persistHistory,
        )

    fun toAppForkThreadFromMessageRequest(cwd: String? = null): AppForkThreadFromMessageRequest =
        AppForkThreadFromMessageRequest(
            model = model,
            cwd = cwd,
            approvalPolicy = approvalPolicy,
            sandbox = sandboxMode,
            developerInstructions = developerInstructions,
            persistExtendedHistory = persistHistory,
        )
}

/**
 * UI-facing payload for composing a message.
 * Converts to Rust [AppStartTurnRequest].
 */
data class AppComposerPayload(
    val text: String,
    val additionalInputs: List<AppUserInput> = emptyList(),
    val fileAttachments: List<ComposerFileAttachment> = emptyList(),
    val approvalPolicy: AppAskForApproval? = null,
    val sandboxPolicy: AppSandboxPolicy? = null,
    val model: String? = null,
    val reasoningEffort: ReasoningEffort? = null,
    val serviceTier: ServiceTier? = null,
) {
    fun toAppStartTurnRequest(threadId: String): AppStartTurnRequest {
        val input = additionalInputs.toMutableList()
        val composedText = desktopStylePromptText(text, fileAttachments)
        if (composedText.isNotBlank()) {
            input.add(0, AppUserInput.Text(text = composedText, textElements = emptyList()))
        }

        return AppStartTurnRequest(
            threadId = threadId,
            input = input,
            approvalPolicy = approvalPolicy,
            sandboxPolicy = sandboxPolicy,
            model = model,
            serviceTier = serviceTier,
            effort = reasoningEffort,
        )
    }
}

private fun desktopStylePromptText(
    text: String,
    fileAttachments: List<ComposerFileAttachment>,
): String {
    val attachments = fileAttachments.mapNotNull { attachment ->
        val label = sanitizeFileContextValue(attachment.label)
        val path = sanitizeFileContextValue(attachment.path)
        if (path.isEmpty()) {
            null
        } else {
            ComposerFileAttachment(label = label.ifEmpty { path }, path = path)
        }
    }
    if (attachments.isEmpty()) return text

    val files = attachments.joinToString(separator = "\n\n") { attachment ->
        "## ${attachment.label}: ${attachment.path}"
    }
    return "# Files mentioned by the user:\n\n$files\n\n## My request for Codex:\n$text"
}

private fun sanitizeFileContextValue(value: String): String =
    value.replace('\r', ' ')
        .replace('\n', ' ')
        .trim()
