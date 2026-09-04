package com.litter.android.state

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppStore
import uniffi.codex_mobile_client.TerminalBackendKind
import uniffi.codex_mobile_client.TerminalOutputListener
import uniffi.codex_mobile_client.TerminalSession
import uniffi.codex_mobile_client.TerminalSize
import uniffi.codex_mobile_client.TerminalSshTrustStore

class TerminalSessionController(
    private val scope: CoroutineScope,
    private val appStore: AppStore = AppModel.shared.store,
) {
    enum class Phase {
        IDLE,
        CONNECTING,
        RUNNING,
        EXITED,
        FAILED,
    }

    data class SshHostTrustChallenge(
        val host: String,
        val port: UShort,
        val fingerprint: String,
        val backend: TerminalBackendKind,
        val isChanged: Boolean,
    )

    var phase by mutableStateOf(Phase.IDLE)
        private set
    var output by mutableStateOf("")
        private set
    var exitCode by mutableStateOf<Int?>(null)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set
    var sshTrustChallenge by mutableStateOf<SshHostTrustChallenge?>(null)
        private set

    var sessionId: String? = null
        private set
    private var listener: TerminalOutputListener? = null
    @Volatile
    private var outputByteSink: ((ByteArray) -> Unit)? = null
    @Volatile
    private var eventGeneration: Int = 0
    private var terminalCols: UShort = 80u
    private var terminalRows: UShort = 24u

    private fun activeSession(): TerminalSession? =
        sessionId?.let { appStore.terminalSessionHandle(it) }

    val canSendInput: Boolean
        get() = phase == Phase.RUNNING

    fun openLocalProot(cwd: String? = null) {
        open(TerminalBackendKind.LocalProot(normalized(cwd)))
    }

    fun open(backend: TerminalBackendKind) {
        if (sessionId != null || phase == Phase.CONNECTING) return
        eventGeneration += 1
        val generation = eventGeneration
        phase = Phase.CONNECTING
        errorMessage = null
        exitCode = null
        sshTrustChallenge = null
        scope.launch {
            try {
                val size = TerminalSize(cols = terminalCols, rows = terminalRows)
                val id = if (backend is TerminalBackendKind.RemoteSsh) {
                    val backendImpl = SshTrustStore(AppModel.shared.appContext)
                    val trustStore = TerminalSshTrustStore(backendImpl)
                    appStore.openTerminalSessionWithTrustStore(backend, size, trustStore)
                } else {
                    appStore.openTerminalSession(backend, size)
                }
                sessionId = id
                appStore.setActiveTerminalId(id)
                val opened = appStore.terminalSessionHandle(id) ?: run {
                    sessionId = null
                    errorMessage = "Session disappeared after open"
                    phase = Phase.FAILED
                    return@launch
                }
                val outputListener = object : TerminalOutputListener {
                    override fun onBytes(data: ByteArray) {
                        if (generation != eventGeneration) return
                        val sink = outputByteSink
                        if (sink != null) {
                            sink(data.copyOf())
                            return
                        }
                        scope.launch(Dispatchers.Main.immediate) {
                            if (generation == eventGeneration) {
                                appendOutput(data)
                            }
                        }
                    }

                    override fun onExit(code: Int) {
                        scope.launch(Dispatchers.Main.immediate) {
                            if (generation == eventGeneration) {
                                exitCode = code
                                phase = Phase.EXITED
                            }
                        }
                    }
                }
                opened.subscribeOutput(outputListener)
                listener = outputListener
                phase = Phase.RUNNING
            } catch (error: Exception) {
                sessionId = null
                val challenge = sshHostTrustChallenge(error, backend)
                if (challenge != null) {
                    sshTrustChallenge = challenge
                    errorMessage = "Unknown SSH host key ${challenge.fingerprint}"
                } else {
                    errorMessage = error.message ?: "Unable to open terminal"
                }
                phase = Phase.FAILED
            }
        }
    }

    fun trustUnknownSshHostAndRetry() {
        val challenge = sshTrustChallenge ?: return
        SshTrustStore(AppModel.shared.appContext).write(
            host = challenge.host,
            port = challenge.port,
            fingerprint = challenge.fingerprint,
        )
        sshTrustChallenge = null
        errorMessage = null
        phase = Phase.IDLE
        open(challenge.backend)
    }

    fun dismissSshTrustChallenge() {
        sshTrustChallenge = null
        errorMessage = null
        phase = Phase.IDLE
    }

    fun switchBackend(backend: TerminalBackendKind) {
        close()
        output = ""
        open(backend)
    }

    fun send(value: String) {
        sendBytes(value.toByteArray(Charsets.UTF_8))
    }

    fun sendBytes(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val activeSession = activeSession() ?: return
        if (!canSendInput) return
        scope.launch {
            try {
                activeSession.writeInput(bytes)
            } catch (error: Exception) {
                errorMessage = error.message ?: "Unable to write terminal input"
                phase = Phase.FAILED
            }
        }
    }

    fun sendLine(value: String) {
        send("$value\n")
    }

    fun clearOutput() {
        output = ""
    }

    fun setOutputByteSink(sink: ((ByteArray) -> Unit)?) {
        outputByteSink = sink
    }

    private fun sshHostTrustChallenge(
        error: Exception,
        backend: TerminalBackendKind,
    ): SshHostTrustChallenge? {
        val sshBackend = backend as? TerminalBackendKind.RemoteSsh ?: return null
        val message = error.message.orEmpty()
        val fingerprint = sshHostFingerprint(message) ?: return null
        return SshHostTrustChallenge(
            host = sshBackend.host,
            port = sshBackend.port,
            fingerprint = fingerprint,
            backend = backend,
            isChanged = message.contains("host-key-changed:"),
        )
    }

    private fun sshHostFingerprint(message: String): String? {
        val markers = listOf("unknown-host:", "host-key-changed:")
        val marker = markers.firstOrNull { message.contains(it) } ?: return null
        val start = message.indexOf(marker)
        if (start < 0) return null
        return message
            .substring(start + marker.length)
            .trim()
            .trim('"', '\'', '(', ')', '[', ']')
            .takeIf { it.isNotEmpty() }
    }

    fun resize(cols: Int, rows: Int, notifyBackend: Boolean = true) {
        if (cols <= 0 || rows <= 0) return
        terminalCols = cols.coerceIn(1, UShort.MAX_VALUE.toInt()).toUShort()
        terminalRows = rows.coerceIn(1, UShort.MAX_VALUE.toInt()).toUShort()
        val activeSession = activeSession() ?: return
        if (!notifyBackend || !canSendInput) return
        val size = TerminalSize(cols = terminalCols, rows = terminalRows)
        scope.launch {
            try {
                activeSession.resize(size)
            } catch (error: Exception) {
                errorMessage = error.message ?: "Unable to resize terminal"
                phase = Phase.FAILED
            }
        }
    }

    fun close() {
        eventGeneration += 1
        val id = sessionId ?: return
        sessionId = null
        listener = null
        phase = Phase.IDLE
        scope.launch {
            runCatching { appStore.closeTerminalSession(id) }
        }
    }

    private fun appendOutput(data: ByteArray) {
        val sink = outputByteSink
        sink?.invoke(data.copyOf())
        if (sink != null) return
        output += data.toString(Charsets.UTF_8)
        trimOutputIfNeeded()
    }

    private fun normalized(value: String?): String? {
        val trimmed = value?.trim().orEmpty()
        return trimmed.ifEmpty { null }
    }

    private fun trimOutputIfNeeded() {
        val maxCount = 64_000
        if (output.length > maxCount) {
            output = output.takeLast(maxCount)
        }
    }
}
