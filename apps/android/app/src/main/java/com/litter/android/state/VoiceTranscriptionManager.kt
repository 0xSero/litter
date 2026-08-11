package com.litter.android.state

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt
import uniffi.codex_mobile_client.AuthMode

/**
 * Records microphone input and transcribes via ChatGPT/OpenAI API.
 * Used for push-to-talk text input in the composer.
 */
class VoiceTranscriptionManager {

    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    private val _isTranscribing = MutableStateFlow(false)
    val isTranscribing: StateFlow<Boolean> = _isTranscribing.asStateFlow()

    private val _audioLevel = MutableStateFlow(0f)
    val audioLevel: StateFlow<Float> = _audioLevel.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private var audioRecord: AudioRecord? = null
    private val buffers = mutableListOf<ShortArray>()
    private var deviceSampleRate = 44100
    private var recordingThread: Thread? = null

    fun hasMicPermission(context: Context): Boolean {
        return ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun startRecording(context: Context) {
        if (_isRecording.value) return
        if (!hasMicPermission(context)) {
            _error.value = "Microphone permission required"
            return
        }

        buffers.clear()
        _error.value = null
        deviceSampleRate = 44100

        val bufferSize = AudioRecord.getMinBufferSize(
            deviceSampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (bufferSize <= 0) {
            _error.value = "Microphone is unavailable"
            return
        }

        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                deviceSampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize * 2,
            ).also { it.startRecording() }
        } catch (_: SecurityException) {
            _error.value = "Microphone permission required"
            return
        } catch (_: IllegalArgumentException) {
            _error.value = "Microphone configuration is unsupported"
            return
        } catch (_: IllegalStateException) {
            _error.value = "Microphone could not start"
            return
        }
        audioRecord = recorder
        _isRecording.value = true

        recordingThread = Thread {
            val buffer = ShortArray(bufferSize / 2)
            while (_isRecording.value) {
                val read = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                if (read > 0) {
                    synchronized(buffers) {
                        buffers.add(buffer.copyOfRange(0, read))
                    }
                    _audioLevel.value = rms(buffer, read)
                }
            }
        }.also { it.start() }
    }

    suspend fun stopAndTranscribe(authMethod: AuthMode?, authToken: String?): String? {
        _isRecording.value = false
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        recordingThread?.join(1000)
        recordingThread = null
        _audioLevel.value = 0f

        val allSamples: ShortArray
        synchronized(buffers) {
            val total = buffers.sumOf { it.size }
            allSamples = ShortArray(total)
            var offset = 0
            for (buf in buffers) {
                buf.copyInto(allSamples, offset)
                offset += buf.size
            }
            buffers.clear()
        }

        // Minimum duration check (0.5 seconds)
        val durationSec = allSamples.size.toFloat() / deviceSampleRate
        if (durationSec < 0.5f) {
            _error.value = "Recording too short"
            return null
        }

        val token = authToken?.trim().orEmpty()
        if (token.isEmpty()) {
            _error.value = "Not logged in."
            return null
        }

        // Resample to 24kHz
        val targetRate = 24000
        val resampled = resample(allSamples, deviceSampleRate, targetRate)
        val wav = encodeWav(resampled, targetRate)

        // Upload for transcription
        _isTranscribing.value = true
        return try {
            withContext(Dispatchers.IO) {
                if (authMethod == AuthMode.API_KEY) {
                    transcribeOpenAI(wav, token)
                } else {
                    transcribeChatGPT(wav, token)
                }
            }
        } catch (e: Exception) {
            _error.value = e.message
            null
        } finally {
            _isTranscribing.value = false
        }
    }

    fun cancelRecording() {
        _isRecording.value = false
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        recordingThread = null
        buffers.clear()
        _audioLevel.value = 0f
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun rms(buffer: ShortArray, size: Int): Float {
        var sum = 0.0
        for (i in 0 until size) {
            val sample = buffer[i].toDouble() / Short.MAX_VALUE
            sum += sample * sample
        }
        return (sqrt(sum / size) * 3).coerceAtMost(1.0).toFloat()
    }

    private fun resample(input: ShortArray, inputRate: Int, outputRate: Int): ShortArray {
        if (inputRate == outputRate) return input
        val ratio = inputRate.toDouble() / outputRate
        val outputSize = (input.size / ratio).toInt()
        val output = ShortArray(outputSize)
        for (i in 0 until outputSize) {
            val srcPos = i * ratio
            val srcIndex = srcPos.toInt()
            val frac = srcPos - srcIndex
            val s0 = input[srcIndex.coerceAtMost(input.size - 1)]
            val s1 = input[(srcIndex + 1).coerceAtMost(input.size - 1)]
            output[i] = (s0 + frac * (s1 - s0)).toInt().toShort()
        }
        return output
    }

    private fun encodeWav(samples: ShortArray, sampleRate: Int): ByteArray {
        val dataSize = samples.size * 2
        val bos = ByteArrayOutputStream(44 + dataSize)
        val dos = DataOutputStream(bos)

        // RIFF header
        dos.writeBytes("RIFF")
        dos.writeIntLE(36 + dataSize)
        dos.writeBytes("WAVE")

        // fmt chunk
        dos.writeBytes("fmt ")
        dos.writeIntLE(16) // chunk size
        dos.writeShortLE(1) // PCM
        dos.writeShortLE(1) // mono
        dos.writeIntLE(sampleRate)
        dos.writeIntLE(sampleRate * 2) // byte rate
        dos.writeShortLE(2) // block align
        dos.writeShortLE(16) // bits per sample

        // data chunk
        dos.writeBytes("data")
        dos.writeIntLE(dataSize)
        val buf = ByteBuffer.allocate(dataSize).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) buf.putShort(s)
        dos.write(buf.array())

        return bos.toByteArray()
    }

    private fun transcribeChatGPT(wav: ByteArray, token: String): String? {
        return uploadMultipart(
            url = "https://chatgpt.com/backend-api/transcribe",
            wav = wav,
            token = token,
            modelField = null,
        )
    }

    private fun transcribeOpenAI(wav: ByteArray, token: String): String? {
        return uploadMultipart(
            url = "https://api.openai.com/v1/audio/transcriptions",
            wav = wav,
            token = token,
            modelField = "gpt-4o-mini-transcribe",
        )
    }

    private fun uploadMultipart(url: String, wav: ByteArray, token: String, modelField: String?): String? {
        val boundary = "----FormBoundary${System.currentTimeMillis()}"
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.setRequestProperty("Authorization", "Bearer $token")
        conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
        conn.doOutput = true

        conn.outputStream.use { os ->
            // File part
            os.write("--$boundary\r\n".toByteArray())
            os.write("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".toByteArray())
            os.write("Content-Type: audio/wav\r\n\r\n".toByteArray())
            os.write(wav)
            os.write("\r\n".toByteArray())

            // Model part (if needed)
            if (modelField != null) {
                os.write("--$boundary\r\n".toByteArray())
                os.write("Content-Disposition: form-data; name=\"model\"\r\n\r\n".toByteArray())
                os.write(modelField.toByteArray())
                os.write("\r\n".toByteArray())
            }

            os.write("--$boundary--\r\n".toByteArray())
        }

        val response = conn.inputStream.bufferedReader().readText()
        conn.disconnect()

        // Parse transcript from JSON response
        return try {
            org.json.JSONObject(response).optString("text").takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            response.takeIf { it.isNotBlank() }
        }
    }

    private fun DataOutputStream.writeIntLE(v: Int) {
        write(v and 0xFF)
        write((v shr 8) and 0xFF)
        write((v shr 16) and 0xFF)
        write((v shr 24) and 0xFF)
    }

    private fun DataOutputStream.writeShortLE(v: Int) {
        write(v and 0xFF)
        write((v shr 8) and 0xFF)
    }
}
