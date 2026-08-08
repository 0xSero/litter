package com.litter.android.state

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.AppAskForApproval
import uniffi.codex_mobile_client.AppReadOnlyAccess
import uniffi.codex_mobile_client.AppDynamicToolSpec
import uniffi.codex_mobile_client.AppSandboxMode
import uniffi.codex_mobile_client.AppSandboxPolicy
import com.litter.android.ui.common.AgentRuntimeKind
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.generativeUiDynamicToolSpecs

data class ThreadPermissionOverride(
    val approvalPolicy: String,
    val sandboxMode: String,
    val isUserOverride: Boolean,
    val rawApprovalPolicy: AppAskForApproval? = null,
    val rawSandboxPolicy: AppSandboxPolicy? = null,
)

data class AppLaunchStateSnapshot(
    val currentCwd: String = "",
    val selectedModel: String = "",
    val selectedAgentRuntimeKind: AgentRuntimeKind? = null,
    val reasoningEffort: String = "",
    val approvalPolicy: String = DEFAULT_APPROVAL_POLICY,
    val sandboxMode: String = DEFAULT_SANDBOX_MODE,
    val threadPermissionOverrides: Map<String, ThreadPermissionOverride> = emptyMap(),
)

internal data class AppLaunchModelSelection(
    val agentRuntimeKind: AgentRuntimeKind?,
    val model: String?,
)

internal fun appLaunchModelSelection(
    modelOverride: String?,
    selectedModel: String?,
    selectedAgentRuntimeKind: AgentRuntimeKind?,
): AppLaunchModelSelection =
    AppLaunchModelSelection(
        agentRuntimeKind = selectedAgentRuntimeKind,
        model = modelOverride.normalizedOrNull() ?: selectedModel.normalizedOrNull(),
    )

internal fun AppLaunchStateSnapshot.updatingSelectedModel(
    model: String?,
    agentRuntimeKind: AgentRuntimeKind?,
): AppLaunchStateSnapshot {
    val normalizedModel = model.normalizedOrEmpty()
    return if (
        selectedModel == normalizedModel &&
        selectedAgentRuntimeKind == agentRuntimeKind
    ) {
        this
    } else {
        copy(
            selectedModel = normalizedModel,
            selectedAgentRuntimeKind = agentRuntimeKind,
        )
    }
}

private const val PREFS_NAME = "litter.launchState"
private const val APPROVAL_POLICY_KEY = "litter.approvalPolicy"
private const val SANDBOX_MODE_KEY = "litter.sandboxMode"
private const val DEFAULT_APPROVAL_POLICY = "inherit"
private const val DEFAULT_SANDBOX_MODE = "inherit"
private const val CUSTOM_PERMISSION_VALUE = "custom"

class AppLaunchState(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val _snapshot = MutableStateFlow(
        AppLaunchStateSnapshot(
            approvalPolicy = prefs.getString(APPROVAL_POLICY_KEY, DEFAULT_APPROVAL_POLICY)
                ?.trim()
                ?.ifEmpty { DEFAULT_APPROVAL_POLICY }
                ?: DEFAULT_APPROVAL_POLICY,
            sandboxMode = prefs.getString(SANDBOX_MODE_KEY, DEFAULT_SANDBOX_MODE)
                ?.trim()
                ?.ifEmpty { DEFAULT_SANDBOX_MODE }
                ?: DEFAULT_SANDBOX_MODE,
        ),
    )

    val snapshot: StateFlow<AppLaunchStateSnapshot> = _snapshot.asStateFlow()

    fun updateCurrentCwd(cwd: String?) {
        val normalized = cwd.normalizedOrEmpty()
        _snapshot.update { state ->
            if (state.currentCwd == normalized) state else state.copy(currentCwd = normalized)
        }
    }

    fun updateSelectedModel(
        model: String?,
        agentRuntimeKind: AgentRuntimeKind? = null,
    ) {
        _snapshot.update { state -> state.updatingSelectedModel(model, agentRuntimeKind) }
    }

    fun updateReasoningEffort(effort: String?) {
        val normalized = effort.normalizedOrEmpty()
        _snapshot.update { state ->
            if (state.reasoningEffort == normalized) state else state.copy(reasoningEffort = normalized)
        }
    }

    fun updateApprovalPolicy(policy: String?) {
        val normalized = policy.normalizedLowercaseOr(default = DEFAULT_APPROVAL_POLICY)
        prefs.edit().putString(APPROVAL_POLICY_KEY, normalized).apply()
        _snapshot.update { state ->
            if (state.approvalPolicy == normalized) state else state.copy(approvalPolicy = normalized)
        }
    }

    fun updateSandboxMode(mode: String?) {
        val normalized = mode.normalizedLowercaseOr(default = DEFAULT_SANDBOX_MODE)
        prefs.edit().putString(SANDBOX_MODE_KEY, normalized).apply()
        _snapshot.update { state ->
            if (state.sandboxMode == normalized) state else state.copy(sandboxMode = normalized)
        }
    }

    fun syncFromThread(thread: AppThreadSnapshot?) {
        updateCurrentCwd(thread?.info?.cwd)
        val threadKey = thread?.key ?: return
        val permissionKey = permissionKey(threadKey)
        val existing = snapshot.value.threadPermissionOverrides[permissionKey]
        if (existing?.isUserOverride == true) {
            return
        }

        val rawApprovalPolicy = thread.effectiveApprovalPolicy
        val rawSandboxPolicy = thread.effectiveSandboxPolicy

        _snapshot.update { state ->
            val nextOverrides = when {
                rawApprovalPolicy == null && rawSandboxPolicy == null ->
                    state.threadPermissionOverrides - permissionKey
                else ->
                    state.threadPermissionOverrides + (
                        permissionKey to ThreadPermissionOverride(
                            approvalPolicy = rawApprovalPolicy.toSelectionValue(),
                            sandboxMode = rawSandboxPolicy.toSelectionValue(),
                            isUserOverride = false,
                            rawApprovalPolicy = rawApprovalPolicy,
                            rawSandboxPolicy = rawSandboxPolicy,
                        )
                    )
            }
            if (nextOverrides == state.threadPermissionOverrides) {
                state
            } else {
                state.copy(threadPermissionOverrides = nextOverrides)
            }
        }
    }

    fun launchConfig(modelOverride: String? = null, threadKey: ThreadKey? = null): AppThreadLaunchConfig {
        val state = snapshot.value
        val selection = appLaunchModelSelection(
            modelOverride = modelOverride,
            selectedModel = state.selectedModel,
            selectedAgentRuntimeKind = state.selectedAgentRuntimeKind,
        )
        return AppThreadLaunchConfig(
            agentRuntimeKind = selection.agentRuntimeKind,
            model = selection.model,
            approvalPolicy = approvalPolicyValue(threadKey),
            sandboxMode = sandboxModeValue(threadKey),
            developerInstructions = null,
            persistHistory = true,
        )
    }

    fun approvalPolicyValue(threadKey: ThreadKey? = null): AppAskForApproval? =
        if (threadKey != null) {
            outboundPermissionOverride(threadKey)?.let { permission ->
                permission.rawApprovalPolicy ?: askForApprovalFromWireValue(permission.approvalPolicy)
            }
        } else {
            askForApprovalFromWireValue(snapshot.value.approvalPolicy)
        }

    fun sandboxModeValue(threadKey: ThreadKey? = null): AppSandboxMode? =
        if (threadKey != null) {
            outboundPermissionOverride(threadKey)?.let { permission ->
                permission.rawSandboxPolicy?.toLaunchSandboxMode()
                    ?: sandboxModeFromWireValue(permission.sandboxMode)
            }
        } else {
            sandboxModeFromWireValue(snapshot.value.sandboxMode)
        }

    fun turnSandboxPolicy(threadKey: ThreadKey? = null): AppSandboxPolicy? =
        if (threadKey != null) {
            outboundPermissionOverride(threadKey)?.let { permission ->
                permission.rawSandboxPolicy ?: sandboxModeFromWireValue(permission.sandboxMode)?.toTurnSandboxPolicy()
            }
        } else {
            sandboxModeValue()?.toTurnSandboxPolicy()
        }

    fun threadStartRequest(
        cwd: String,
        modelOverride: String? = null,
        serverIsLocal: Boolean = false,
    ) =
        launchConfig(modelOverride).toAppStartThreadRequest(
            cwd = cwd.normalizedOrFallback(
                if (serverIsLocal) HomeAnchor.path(appContext) else "/",
            ),
            dynamicTools = if (serverIsLocal) generativeUiDynamicToolSpecs() else null,
        ).also { updateCurrentCwd(it.cwd) }

    fun threadResumeRequest(
        threadId: String,
        cwdOverride: String? = null,
        modelOverride: String? = null,
        threadKey: ThreadKey? = null,
    ) = launchConfig(modelOverride, threadKey).toAppResumeThreadRequest(threadId, resolvedCwdOverride(cwdOverride))

    fun threadForkRequest(
        sourceThreadId: String,
        cwdOverride: String? = null,
        modelOverride: String? = null,
        threadKey: ThreadKey? = null,
    ) = launchConfig(modelOverride, threadKey).toAppForkThreadRequest(sourceThreadId, resolvedCwdOverride(cwdOverride))
        .also { updateCurrentCwd(it.cwd) }

    fun forkThreadFromMessageRequest(
        cwdOverride: String? = null,
        modelOverride: String? = null,
        threadKey: ThreadKey? = null,
    ) = launchConfig(modelOverride, threadKey).toAppForkThreadFromMessageRequest(resolvedCwdOverride(cwdOverride))
        .also { updateCurrentCwd(it.cwd) }

    fun permissionOverride(threadKey: ThreadKey?): ThreadPermissionOverride? =
        threadKey?.let { snapshot.value.threadPermissionOverrides[permissionKey(it)] }

    private fun outboundPermissionOverride(threadKey: ThreadKey?): ThreadPermissionOverride? =
        permissionOverride(threadKey)?.takeIf { it.isUserOverride }

    fun selectedApprovalPolicy(threadKey: ThreadKey? = null): String =
        if (threadKey != null) {
            permissionOverride(threadKey)?.approvalPolicy ?: DEFAULT_APPROVAL_POLICY
        } else {
            snapshot.value.approvalPolicy
        }

    fun selectedSandboxMode(threadKey: ThreadKey? = null): String =
        if (threadKey != null) {
            permissionOverride(threadKey)?.sandboxMode ?: DEFAULT_SANDBOX_MODE
        } else {
            snapshot.value.sandboxMode
        }

    fun updateThreadPermissions(threadKey: ThreadKey?, approvalPolicy: String?, sandboxMode: String?) {
        if (threadKey == null) {
            updateApprovalPolicy(approvalPolicy)
            updateSandboxMode(sandboxMode)
            return
        }
        val normalizedApproval = approvalPolicy.normalizedLowercaseOr(default = DEFAULT_APPROVAL_POLICY)
        val normalizedSandbox = sandboxMode.normalizedLowercaseOr(default = DEFAULT_SANDBOX_MODE)
        _snapshot.update { state ->
            val nextOverrides = state.threadPermissionOverrides + (
                permissionKey(threadKey) to ThreadPermissionOverride(
                    approvalPolicy = normalizedApproval,
                    sandboxMode = normalizedSandbox,
                    isUserOverride = true,
                    rawApprovalPolicy = askForApprovalFromWireValue(normalizedApproval),
                    rawSandboxPolicy = sandboxModeFromWireValue(normalizedSandbox)?.toTurnSandboxPolicy(),
                )
            )
            state.copy(threadPermissionOverrides = nextOverrides)
        }
    }

    private fun resolvedCwdOverride(cwdOverride: String?): String? =
        cwdOverride.normalizedOrNull() ?: snapshot.value.currentCwd.normalizedOrNull()

    private fun permissionKey(threadKey: ThreadKey): String = "${threadKey.serverId}/${threadKey.threadId}"
}

private fun askForApprovalFromWireValue(value: String?): AppAskForApproval? =
    when (value.normalizedLowercaseOr(default = "")) {
        "untrusted", "unless-trusted" -> AppAskForApproval.UnlessTrusted
        "on-failure" -> AppAskForApproval.OnFailure
        "on-request" -> AppAskForApproval.OnRequest
        "never" -> AppAskForApproval.Never
        else -> null
    }

private fun sandboxModeFromWireValue(value: String?): AppSandboxMode? =
    when (value.normalizedLowercaseOr(default = "")) {
        "read-only" -> AppSandboxMode.READ_ONLY
        "workspace-write" -> AppSandboxMode.WORKSPACE_WRITE
        "danger-full-access" -> AppSandboxMode.DANGER_FULL_ACCESS
        else -> null
    }

fun AppSandboxMode.toTurnSandboxPolicy(): AppSandboxPolicy =
    when (this) {
        AppSandboxMode.READ_ONLY -> AppSandboxPolicy.ReadOnly(
            access = AppReadOnlyAccess.FullAccess,
            networkAccess = false,
        )
        AppSandboxMode.WORKSPACE_WRITE -> AppSandboxPolicy.WorkspaceWrite(
            writableRoots = emptyList(),
            readOnlyAccess = AppReadOnlyAccess.FullAccess,
            networkAccess = false,
            excludeTmpdirEnvVar = false,
            excludeSlashTmp = false,
        )
        AppSandboxMode.DANGER_FULL_ACCESS -> AppSandboxPolicy.DangerFullAccess
    }

private fun AppAskForApproval?.toWireValue(): String? =
    when (this) {
        AppAskForApproval.UnlessTrusted -> "untrusted"
        AppAskForApproval.OnFailure -> "on-failure"
        AppAskForApproval.OnRequest -> "on-request"
        AppAskForApproval.Never -> "never"
        is AppAskForApproval.Granular, null -> null
    }

private fun AppAskForApproval?.toSelectionValue(): String =
    when (this) {
        null -> DEFAULT_APPROVAL_POLICY
        else -> toWireValue() ?: CUSTOM_PERMISSION_VALUE
    }

private fun AppSandboxPolicy?.toSandboxModeWireValue(): String? =
    when (this) {
        AppSandboxPolicy.DangerFullAccess -> "danger-full-access"
        is AppSandboxPolicy.ReadOnly -> "read-only"
        is AppSandboxPolicy.WorkspaceWrite -> "workspace-write"
        is AppSandboxPolicy.ExternalSandbox, null -> null
    }

private fun AppSandboxPolicy?.toSelectionValue(): String =
    when (this) {
        null -> DEFAULT_SANDBOX_MODE
        else -> toSandboxModeWireValue() ?: CUSTOM_PERMISSION_VALUE
    }

private fun AppSandboxPolicy.toLaunchSandboxMode(): AppSandboxMode? =
    when (this) {
        AppSandboxPolicy.DangerFullAccess -> AppSandboxMode.DANGER_FULL_ACCESS
        is AppSandboxPolicy.ReadOnly -> AppSandboxMode.READ_ONLY
        is AppSandboxPolicy.WorkspaceWrite -> AppSandboxMode.WORKSPACE_WRITE
        is AppSandboxPolicy.ExternalSandbox -> null
    }

private fun String?.normalizedOrEmpty(): String = this?.trim().orEmpty()

private fun String?.normalizedOrNull(): String? = normalizedOrEmpty().ifEmpty { null }

private fun String?.normalizedLowercaseOr(default: String): String =
    normalizedOrEmpty().lowercase().ifEmpty { default }

private fun String?.normalizedOrFallback(fallback: String): String =
    normalizedOrEmpty().ifEmpty { fallback }
