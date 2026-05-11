package com.litter.android.ui.settings

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import com.litter.android.auth.ChatGPTOAuthActivity
import com.litter.android.state.ChatGPTOAuth
import com.litter.android.state.ChatGPTOAuthTokenStore
import com.litter.android.state.OpenAIApiKeyStore
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import com.litter.android.util.LLog
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.Account
import uniffi.codex_mobile_client.AppRefreshAccountRequest
import uniffi.codex_mobile_client.AppLoginAccountRequest

/**
 * Account login/logout management for a specific server.
 */
@Composable
fun AccountSheet(
    serverId: String,
    onDismiss: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()

    val server = remember(snapshot, serverId) {
        snapshot?.servers?.find { it.serverId == serverId }
    }
    val account = server?.account
    val apiKeyStore = remember(context) { OpenAIApiKeyStore(context.applicationContext) }
    var apiKey by remember { mutableStateOf("") }
    var openAIBaseUrl by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var isAuthWorking by remember { mutableStateOf(false) }
    var hasStoredApiKey by remember { mutableStateOf(apiKeyStore.hasStoredKey()) }
    var hasStoredBaseUrl by remember { mutableStateOf(apiKeyStore.hasStoredBaseUrl()) }
    val authLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        isAuthWorking = false
        LLog.d("ChatGPTOAuth", "account sheet auth result", fields = mapOf("resultCode" to result.resultCode))
        if (result.resultCode == Activity.RESULT_OK) {
            val tokens = ChatGPTOAuthActivity.parseResult(result.data)
            if (tokens == null) {
                error = "ChatGPT login returned incomplete credentials."
                LLog.w("ChatGPTOAuth", "account sheet auth result missing tokens")
                return@rememberLauncherForActivityResult
            }
            scope.launch {
                try {
                    LLog.d("ChatGPTOAuth", "account sheet loginAccount starting")
                    appModel.client.loginAccount(
                        serverId,
                        AppLoginAccountRequest.ChatgptAuthTokens(
                            accessToken = tokens.accessToken,
                            chatgptAccountId = tokens.accountId,
                            chatgptPlanType = tokens.planType,
                        ),
                    )
                    appModel.refreshSnapshot()
                    error = null
                    LLog.i("ChatGPTOAuth", "account sheet loginAccount succeeded")
                } catch (e: Exception) {
                    error = e.localizedMessage ?: e.message
                    LLog.e("ChatGPTOAuth", "account sheet loginAccount failed", e)
                }
            }
        } else {
            error = result.data?.getStringExtra(ChatGPTOAuthActivity.EXTRA_ERROR)
            error?.let { LLog.w("ChatGPTOAuth", "account sheet auth canceled", fields = mapOf("error" to it)) }
        }
    }

    val allowsLocalEnvApiKey = server?.isLocal == true
    val isChatGPTAccount = account is Account.Chatgpt

    androidx.compose.runtime.LaunchedEffect(serverId, account) {
        hasStoredApiKey = apiKeyStore.hasStoredKey()
        hasStoredBaseUrl = apiKeyStore.hasStoredBaseUrl()
    }

    androidx.compose.runtime.LaunchedEffect(serverId) {
        runCatching {
            appModel.client.refreshAccount(
                serverId,
                AppRefreshAccountRequest(refreshToken = false),
            )
            appModel.refreshSnapshot()
            error = null
        }.onFailure { throwable ->
            error = throwable.localizedMessage ?: throwable.message
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .imePadding()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = "Account",
            color = LitterTheme.textPrimary,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
        )

        Text(
            text = server?.displayName ?: serverId,
            color = LitterTheme.textSecondary,
            fontSize = 13.sp,
        )

        // Current account status
        when (account) {
            is Account.Chatgpt -> {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                        .padding(12.dp),
                ) {
                    Text("Logged in", color = LitterTheme.accent, fontSize = 13.sp)
                    Text(account.email, color = LitterTheme.textPrimary, fontSize = 14.sp)
                }
            }

            is Account.ApiKey -> {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                        .padding(12.dp),
                ) {
                    Text("API key configured", color = LitterTheme.accent, fontSize = 13.sp)
                }
            }

            null -> Unit
        }

        if (server?.isLocal == true && hasStoredApiKey) {
            Text(
                "Local OpenAI API key is saved.",
                color = LitterTheme.accent,
                fontSize = 12.sp,
            )
        }

        if (server?.isLocal == true && hasStoredBaseUrl) {
            Text(
                "OpenAI-compatible base URL is saved.",
                color = LitterTheme.accent,
                fontSize = 12.sp,
            )
        }

        if (server?.isLocal == true && account != null) {
            OutlinedButton(
                onClick = {
                    scope.launch {
                            ChatGPTOAuthTokenStore(context).clear()
                            apiKeyStore.clear()
                            appModel.client.logoutAccount(serverId)
                            appModel.restartLocalServer()
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Logout")
            }
        }

        if (server?.isLocal == true && !isChatGPTAccount) {
            Button(
                onClick = {
                    try {
                        error = null
                        isAuthWorking = true
                        authLauncher.launch(
                            ChatGPTOAuthActivity.createIntent(
                                context,
                                ChatGPTOAuth.createLoginAttempt(),
                            ),
                        )
                    } catch (e: Exception) {
                        isAuthWorking = false
                        error = e.localizedMessage ?: e.message
                    }
                },
                colors = ButtonDefaults.buttonColors(
                    containerColor = LitterTheme.accent,
                    contentColor = Color.Black,
                ),
                modifier = Modifier.fillMaxWidth(),
                enabled = !isAuthWorking,
            ) {
                Text("Login with ChatGPT")
            }
        }

        if (allowsLocalEnvApiKey) {
            if (hasStoredApiKey) {
                Text(
                    "OpenAI API key saved in the local environment.",
                    color = LitterTheme.textSecondary,
                    fontSize = 12.sp,
                )
            } else if (isChatGPTAccount) {
                Text(
                    "Save an OpenAI API key in the local Codex environment.",
                    color = LitterTheme.textSecondary,
                    fontSize = 12.sp,
                )
            } else {
                Text("Or save an API key for the local environment:", color = LitterTheme.textSecondary, fontSize = 12.sp)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = apiKey,
                    onValueChange = { apiKey = it },
                    label = { Text("API Key") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.weight(1f),
                )
                Button(
                    onClick = {
                        scope.launch {
                            try {
                                apiKeyStore.save(apiKey.trim())
                                if (account is Account.ApiKey) {
                                    appModel.client.logoutAccount(serverId)
                                }
                                appModel.restartLocalServer()
                                hasStoredApiKey = apiKeyStore.hasStoredKey()
                                if (hasStoredApiKey) {
                                    apiKey = ""
                                } else {
                                    error = "API key did not persist locally."
                                    return@launch
                                }
                                error = null
                            } catch (e: Exception) {
                                error = e.message
                            }
                        }
                    },
                    enabled = apiKey.isNotBlank(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = LitterTheme.accent,
                        contentColor = Color.Black,
                    ),
                ) {
                    Text(if (hasStoredApiKey) "Update API Key" else "Save API Key")
                }
            }

            Text(
                if (hasStoredBaseUrl) {
                    "Custom OpenAI-compatible endpoint saved for the local Codex server."
                } else {
                    "Optional OpenAI-compatible endpoint for local models."
                },
                color = LitterTheme.textSecondary,
                fontSize = 12.sp,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = openAIBaseUrl,
                    onValueChange = { openAIBaseUrl = it },
                    label = { Text("Base URL") },
                    placeholder = { Text("http://host:port/v1") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                Button(
                    onClick = {
                        val normalized = normalizeOpenAIBaseUrl(openAIBaseUrl)
                        if (normalized == null) {
                            error = "Enter a valid http or https base URL."
                        } else {
                            scope.launch {
                                isAuthWorking = true
                                try {
                                    apiKeyStore.saveBaseUrl(normalized)
                                    appModel.restartLocalServer()
                                    hasStoredBaseUrl = apiKeyStore.hasStoredBaseUrl()
                                    if (hasStoredBaseUrl) {
                                        openAIBaseUrl = ""
                                        error = null
                                    } else {
                                        error = "Base URL did not persist locally."
                                    }
                                } catch (e: Exception) {
                                    error = e.message
                                } finally {
                                    isAuthWorking = false
                                }
                            }
                        }
                    },
                    enabled = openAIBaseUrl.isNotBlank() && !isAuthWorking,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = LitterTheme.accent,
                        contentColor = Color.Black,
                    ),
                ) {
                    Text(if (hasStoredBaseUrl) "Update" else "Save")
                }
            }
            if (hasStoredBaseUrl) {
                OutlinedButton(
                    onClick = {
                        scope.launch {
                            isAuthWorking = true
                            try {
                                apiKeyStore.clearBaseUrl()
                                appModel.restartLocalServer()
                                hasStoredBaseUrl = apiKeyStore.hasStoredBaseUrl()
                                openAIBaseUrl = ""
                                error = null
                            } catch (e: Exception) {
                                error = e.message
                            } finally {
                                isAuthWorking = false
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isAuthWorking,
                ) {
                    Text("Clear Base URL")
                }
            }
        } else if (server?.isLocal == false) {
            Text(
                "Remote servers request their own OAuth login when needed. Account login and API key entry stay local-only.",
                color = LitterTheme.textSecondary,
                fontSize = 12.sp,
            )
        }

        error?.let {
            Text(it, color = LitterTheme.danger, fontSize = 12.sp)
        }
    }
}

private fun normalizeOpenAIBaseUrl(rawValue: String): String? {
    val trimmed = rawValue.trim().trimEnd('/')
    if (trimmed.isEmpty()) return null
    val uri = runCatching { java.net.URI(trimmed) }.getOrNull() ?: return null
    val scheme = uri.scheme?.lowercase()
    if (scheme != "http" && scheme != "https") return null
    if (uri.host.isNullOrBlank()) return null
    return trimmed
}
