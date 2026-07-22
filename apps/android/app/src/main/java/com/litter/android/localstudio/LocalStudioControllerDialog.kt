package com.litter.android.localstudio

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.AppModel
import com.litter.android.ui.LitterTheme
import uniffi.codex_mobile_client.LocalStudioControllerLoadResult
import uniffi.codex_mobile_client.LocalStudioControllerSnapshot
import uniffi.codex_mobile_client.LocalStudioSessionDescriptor
import uniffi.codex_mobile_client.LocalStudioSessionListResult

/** Minimal signed controller dashboard; chat/tools/files stay in the shared Pi UI. */
@Composable
fun LocalStudioControllerDialog(
    appModel: AppModel,
    serverId: String,
    onDismiss: () -> Unit,
) {
    var snapshot by remember(serverId) { mutableStateOf<LocalStudioControllerSnapshot?>(null) }
    var sessions by remember(serverId) { mutableStateOf<List<LocalStudioSessionDescriptor>>(emptyList()) }
    var error by remember(serverId) { mutableStateOf<String?>(null) }
    var refresh by remember(serverId) { mutableStateOf(0) }
    var loading by remember(serverId) { mutableStateOf(true) }

    LaunchedEffect(serverId, refresh) {
        loading = true
        error = null
        runCatching {
            when (val result = appModel.client.loadLocalStudioController(serverId)) {
                is LocalStudioControllerLoadResult.Loaded -> snapshot = result.snapshot
                is LocalStudioControllerLoadResult.Error -> error = result.error.error.message
            }
            when (val result = appModel.client.listLocalStudioSessions(serverId, 20uL)) {
                is LocalStudioSessionListResult.Page -> sessions = result.page.sessions
                is LocalStudioSessionListResult.Error -> error = result.error.error.message
            }
        }.onFailure { error = it.message ?: "Could not reach Local Studio" }
        loading = false
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Local Studio") },
        text = {
            Column(
                Modifier.fillMaxWidth().heightIn(max = 520.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (loading && snapshot == null) CircularProgressIndicator(color = LitterTheme.accent)
                error?.let { Text(it, color = LitterTheme.warning, fontSize = 12.sp) }
                snapshot?.let { value ->
                    Section("Controller")
                    ValueRow("Name", value.displayName)
                    ValueRow("State", value.state.toString())
                    ValueRow("Revision", value.revision.toString())
                    value.sections.status.value?.let { status ->
                        ValueRow("Runtime", if (status.running) "Running" else "Stopped")
                        ValueRow("Models", status.activeModelIds.ifEmpty { listOf("None running") }.joinToString())
                    }
                    value.sections.gpus.value?.let { gpu ->
                        Section("GPUs")
                        gpu.devices.forEach { device ->
                            val utilization = device.utilizationPercent?.let { "${it.toInt()}%" } ?: "Not reported"
                            ValueRow(device.name, utilization)
                        }
                    }
                }
                if (sessions.isNotEmpty()) {
                    Section("Pi sessions")
                    sessions.forEach { session ->
                        Text(
                            session.metadata.title ?: "Untitled session",
                            color = LitterTheme.textPrimary,
                            fontSize = 12.sp,
                        )
                        Text(
                            session.metadata.modelId ?: session.metadata.cwd ?: "Local Studio",
                            color = LitterTheme.textMuted,
                            fontSize = 10.sp,
                            modifier = Modifier.padding(bottom = 4.dp),
                        )
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { refresh += 1 }) { Text("Refresh") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

@Composable
private fun Section(title: String) =
    Text(title, color = LitterTheme.accent, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)

@Composable
private fun ValueRow(label: String, value: String) {
    Text("$label · $value", color = LitterTheme.textSecondary, fontSize = 11.sp)
}
