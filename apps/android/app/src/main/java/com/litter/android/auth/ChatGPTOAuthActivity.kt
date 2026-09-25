package com.litter.android.auth

import android.content.res.Configuration
import com.litter.android.util.EdgeToEdge
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.lifecycle.lifecycleScope
import com.litter.android.state.ChatGPTOAuth
import com.litter.android.state.ChatGPTOAuthTokenBundle
import com.litter.android.ui.LitterAppTheme
import com.litter.android.ui.LitterTheme
import com.litter.android.util.LLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class ChatGPTOAuthActivity : ComponentActivity() {
    private lateinit var attempt: ChatGPTOAuth.AuthAttempt
    private var isCompleting by mutableStateOf(false)
    private var authJob: Job? = null
    private var loopbackServer: ChatGPTOAuthLoopbackServer? = null
    private var pendingTokens: ChatGPTOAuthTokenBundle? = null
    private var pendingStepUpToken: String? = null
    private var pageError by mutableStateOf<String?>(null)
    private var isLaunchingBrowser by mutableStateOf(false)
    private var browserOpened by mutableStateOf(false)
    private var didReceiveBrowserReturn by mutableStateOf(false)
    private var browserReturnGeneration = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        EdgeToEdge.apply(
            this,
            darkBars = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                Configuration.UI_MODE_NIGHT_YES,
        )

        val authAttempt = parseAttempt(intent)
        if (authAttempt == null) {
            finishWithError("ChatGPT login could not start.")
            return
        }
        attempt = authAttempt
        browserReturnGeneration = ChatGPTOAuthAppReturnSignal.snapshot()
        LLog.i("ChatGPTOAuth", "auth activity created")

        setContent {
            LitterAppTheme {
                ChatGPTOAuthActivityScreen(
                    pageError = pageError,
                    isLaunchingBrowser = isLaunchingBrowser,
                    isCompleting = isCompleting,
                    browserOpened = browserOpened,
                    onClose = {
                        authJob?.cancel()
                        loopbackServer?.close()
                        setResult(Activity.RESULT_CANCELED)
                        finish()
                    },
                    onOpenBrowser = ::launchBrowser,
                )
            }
        }

        beginAuthorization()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == ACTION_BROWSER_RETURN) {
            didReceiveBrowserReturn = true
            browserOpened = false
            LLog.d("ChatGPTOAuth", "browser returned to app")
            finishIfReady()
        }
    }

    override fun onResume() {
        super.onResume()
        val currentGeneration = ChatGPTOAuthAppReturnSignal.snapshot()
        if (!didReceiveBrowserReturn && currentGeneration > browserReturnGeneration) {
            didReceiveBrowserReturn = true
            browserOpened = false
            LLog.d("ChatGPTOAuth", "browser returned to app")
            finishIfReady()
        }
    }

    override fun onDestroy() {
        authJob?.cancel()
        loopbackServer?.close()
        super.onDestroy()
    }

    private fun beginAuthorization() {
        if (authJob != null) return

        authJob = lifecycleScope.launch {
            try {
                pageError = null
                isLaunchingBrowser = true
                val receiver = withContext(Dispatchers.IO) {
                    ChatGPTOAuthLoopbackServer.create(
                        redirectUri = attempt.redirectUri,
                        appReturnUri = APP_RETURN_URI,
                    )
                }
                loopbackServer = receiver
                LLog.d("ChatGPTOAuth", "loopback server started")

                if (!launchBrowser()) {
                    receiver.close()
                    loopbackServer = null
                    isLaunchingBrowser = false
                    authJob = null
                    return@launch
                }

                browserOpened = true
                isLaunchingBrowser = false
                LLog.d("ChatGPTOAuth", "browser launched")
                val callbackUri = withContext(Dispatchers.IO) {
                    receiver.awaitCallback()
                }
                LLog.d("ChatGPTOAuth", "oauth localhost callback received")

                if (isCompleting) return@launch
                isCompleting = true
                if (attempt.mode == ChatGPTOAuth.MODE_REMOTE_CONTROL_ENROLL) {
                    pendingStepUpToken = ChatGPTOAuth.completeRemoteControlEnrollmentAuthorization(
                        callbackUri = callbackUri,
                        attempt = attempt,
                    )
                } else {
                    pendingTokens = ChatGPTOAuth.completeAuthorization(
                        context = applicationContext,
                        callbackUri = callbackUri,
                        attempt = attempt,
                    )
                }
                LLog.i("ChatGPTOAuth", "token exchange completed")
                finishIfReady()
            } catch (_: CancellationException) {
                // Activity closed or recreated.
            } catch (e: Exception) {
                LLog.e("ChatGPTOAuth", "auth flow failed", e)
                finishWithError(e.localizedMessage ?: e.message ?: "ChatGPT login failed.")
            } finally {
                isLaunchingBrowser = false
                loopbackServer?.close()
                loopbackServer = null
                authJob = null
            }
        }
    }

    private fun finishIfReady() {
        val tokens = pendingTokens
        val stepUpToken = pendingStepUpToken
        if (tokens == null && stepUpToken == null) return
        if (!didReceiveBrowserReturn && ChatGPTOAuthAppReturnSignal.snapshot() > browserReturnGeneration) {
            didReceiveBrowserReturn = true
            browserOpened = false
            LLog.d("ChatGPTOAuth", "browser return observed while finalizing")
        }
        if (!didReceiveBrowserReturn) return
        LLog.i("ChatGPTOAuth", "finishing auth activity with tokens")
        setResult(
            Activity.RESULT_OK,
            if (stepUpToken != null) stepUpResultIntent(stepUpToken) else resultIntent(tokens!!),
        )
        finish()
    }

    private fun launchBrowser(): Boolean {
        val authUri = Uri.parse(attempt.authorizeUrl)
        return try {
            CustomTabsIntent.Builder()
                .setShowTitle(true)
                .build()
                .launchUrl(this, authUri)
            true
        } catch (_: ActivityNotFoundException) {
            try {
                startActivity(Intent(Intent.ACTION_VIEW, authUri))
                true
            } catch (e: Exception) {
                pageError = e.localizedMessage ?: e.message ?: "No browser is available for ChatGPT login."
                false
            }
        } catch (e: Exception) {
            pageError = e.localizedMessage ?: e.message ?: "ChatGPT login could not open a browser."
            false
        }
    }

    private fun finishWithError(message: String) {
        setResult(
            Activity.RESULT_CANCELED,
            Intent().putExtra(EXTRA_ERROR, message),
        )
        finish()
    }

    private fun parseAttempt(intent: Intent?): ChatGPTOAuth.AuthAttempt? {
        intent ?: return null
        val state = intent.getStringExtra(EXTRA_STATE) ?: return null
        val codeVerifier = intent.getStringExtra(EXTRA_CODE_VERIFIER) ?: return null
        val redirectUri = intent.getStringExtra(EXTRA_REDIRECT_URI) ?: return null
        val authorizeUrl = intent.getStringExtra(EXTRA_AUTHORIZE_URL) ?: return null
        val mode = intent.getStringExtra(EXTRA_MODE) ?: ChatGPTOAuth.MODE_LOGIN
        return ChatGPTOAuth.AuthAttempt(
            state = state,
            codeVerifier = codeVerifier,
            redirectUri = redirectUri,
            authorizeUrl = authorizeUrl,
            mode = mode,
        )
    }

    companion object {
        const val ACTION_BROWSER_RETURN = "com.litter.android.auth.CHATGPT_BROWSER_RETURN"
        private const val APP_RETURN_HOST = "chatgpt-auth-complete"
        private val APP_RETURN_URI: Uri = Uri.Builder()
            .scheme("litterauth")
            .authority(APP_RETURN_HOST)
            .build()
        private const val EXTRA_STATE = "chatgpt_auth_state"
        private const val EXTRA_CODE_VERIFIER = "chatgpt_auth_code_verifier"
        private const val EXTRA_REDIRECT_URI = "chatgpt_auth_redirect_uri"
        private const val EXTRA_AUTHORIZE_URL = "chatgpt_auth_authorize_url"
        private const val EXTRA_MODE = "chatgpt_auth_mode"
        private const val EXTRA_ACCESS_TOKEN = "chatgpt_auth_access_token"
        private const val EXTRA_STEP_UP_TOKEN = "chatgpt_auth_step_up_token"
        private const val EXTRA_ACCOUNT_ID = "chatgpt_auth_account_id"
        private const val EXTRA_PLAN_TYPE = "chatgpt_auth_plan_type"
        const val EXTRA_ERROR = "chatgpt_auth_error"

        fun createIntent(context: Context, attempt: ChatGPTOAuth.AuthAttempt): Intent =
            Intent(context, ChatGPTOAuthActivity::class.java)
                .putExtra(EXTRA_STATE, attempt.state)
                .putExtra(EXTRA_CODE_VERIFIER, attempt.codeVerifier)
                .putExtra(EXTRA_REDIRECT_URI, attempt.redirectUri)
                .putExtra(EXTRA_AUTHORIZE_URL, attempt.authorizeUrl)
                .putExtra(EXTRA_MODE, attempt.mode)

        fun parseResult(intent: Intent?): ChatGPTOAuthTokenBundle? {
            intent ?: return null
            val accessToken = intent.getStringExtra(EXTRA_ACCESS_TOKEN) ?: return null
            val accountId = intent.getStringExtra(EXTRA_ACCOUNT_ID) ?: return null
            return ChatGPTOAuthTokenBundle(
                accessToken = accessToken,
                idToken = "",
                refreshToken = null,
                accountId = accountId,
                planType = intent.getStringExtra(EXTRA_PLAN_TYPE),
            )
        }

        fun parseRemoteControlStepUpToken(intent: Intent?): String? =
            intent?.getStringExtra(EXTRA_STEP_UP_TOKEN)?.trim()?.takeIf { it.isNotEmpty() }

        private fun resultIntent(tokens: ChatGPTOAuthTokenBundle): Intent =
            Intent()
                .putExtra(EXTRA_ACCESS_TOKEN, tokens.accessToken)
                .putExtra(EXTRA_ACCOUNT_ID, tokens.accountId)
                .putExtra(EXTRA_PLAN_TYPE, tokens.planType)

        private fun stepUpResultIntent(token: String): Intent =
            Intent().putExtra(EXTRA_STEP_UP_TOKEN, token)
    }
}

@Composable
private fun ChatGPTOAuthActivityScreen(
    pageError: String?,
    isLaunchingBrowser: Boolean,
    isCompleting: Boolean,
    browserOpened: Boolean,
    onClose: () -> Unit,
    onOpenBrowser: () -> Boolean,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(LitterTheme.background),
    ) {
        Box(
            modifier = Modifier
                .align(Alignment.TopStart)
                .fillMaxWidth()
                .statusBarsPadding()
                .background(LitterTheme.background)
                .zIndex(1f),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(56.dp)
                    .padding(horizontal = 8.dp),
            ) {
                IconButton(
                    onClick = onClose,
                    enabled = !isCompleting,
                ) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Close login",
                        tint = LitterTheme.textPrimary,
                    )
                }
                Spacer(Modifier.width(4.dp))
                Text(
                    text = "ChatGPT Login",
                    color = LitterTheme.textPrimary,
                    fontSize = 16.sp,
                )
            }
        }

        Column(
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 28.dp),
        ) {
            if (isLaunchingBrowser || isCompleting) {
                CircularProgressIndicator(color = LitterTheme.accent)
                Spacer(Modifier.height(20.dp))
            }

            Text(
                text = if (browserOpened) {
                    "Continue the ChatGPT login in your browser."
                } else {
                    "Opening a secure browser for ChatGPT login."
                },
                color = LitterTheme.textPrimary,
                fontSize = 18.sp,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = if (browserOpened) {
                    "After the login finishes, this screen will complete automatically. If the browser closed early, you can open it again below."
                } else {
                    "Google blocks sign-in inside embedded web views, so Litter uses your browser for this flow."
                },
                color = LitterTheme.textSecondary,
                fontSize = 13.sp,
                textAlign = TextAlign.Center,
            )

            pageError?.let { message ->
                Spacer(Modifier.height(16.dp))
                Text(
                    text = message,
                    color = LitterTheme.danger,
                    fontSize = 12.sp,
                    textAlign = TextAlign.Center,
                )
            }

            Spacer(Modifier.height(24.dp))
            Button(
                onClick = { onOpenBrowser() },
                enabled = !isLaunchingBrowser && !isCompleting,
            ) {
                Text(if (browserOpened) "Open browser again" else "Open browser")
            }
        }

        if (isCompleting) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.88f)),
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(28.dp),
                    color = LitterTheme.accent,
                )
            }
        }
    }
}
