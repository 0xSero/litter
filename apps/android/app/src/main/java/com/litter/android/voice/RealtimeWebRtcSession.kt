package com.litter.android.voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.audio.JavaAudioDeviceModule
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class RealtimeWebRtcSessionException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)

internal const val REALTIME_ICE_GATHERING_TIMEOUT_MS = 5_000L

internal fun realtimePeerConnectionConfiguration(): PeerConnection.RTCConfiguration =
    PeerConnection.RTCConfiguration(emptyList()).apply {
        sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        // The initial SDP is sent as a complete, non-trickle offer. Continuous
        // gathering never transitions to COMPLETE on some Android devices.
        continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE
    }

class RealtimeWebRtcSession(private val context: Context) {

    private val audioManager: AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var peerConnection: PeerConnection? = null
    private var dataChannel: DataChannel? = null
    private var audioSource: AudioSource? = null
    private var audioTrack: AudioTrack? = null
    private val isClosed = AtomicBoolean(false)

    private var previousAudioMode: Int = audioManager.mode
    private var previousSpeakerphoneOn: Boolean = audioManager.isSpeakerphoneOn
    private var audioFocusRequest: AudioFocusRequest? = null
    private val didConfigureAudio = AtomicBoolean(false)

    private var iceGatheringContinuation: kotlinx.coroutines.CancellableContinuation<Unit>? = null

    suspend fun start(): String {
        if (peerConnection != null) {
            throw RealtimeWebRtcSessionException("session already started")
        }
        isClosed.set(false)

        Log.i(TAG, "start: configuring audio session")
        configureAudio()

        Log.i(TAG, "start: acquiring shared PeerConnectionFactory")
        val factory = sharedFactory(context)
        val rtcConfig = realtimePeerConnectionConfiguration()

        Log.i(TAG, "start: creating PeerConnection")
        val connection = factory.createPeerConnection(rtcConfig, DelegateAdapter())
            ?: run {
                releaseAudio()
                throw RealtimeWebRtcSessionException("PeerConnectionFactory.createPeerConnection returned null")
            }
        peerConnection = connection

        val source = factory.createAudioSource(MediaConstraints())
        audioSource = source
        val track = factory.createAudioTrack("realtime-audio", source)
        audioTrack = track

        val transceiverInit = RtpTransceiver.RtpTransceiverInit(
            RtpTransceiver.RtpTransceiverDirection.SEND_RECV,
            listOf("realtime")
        )
        connection.addTransceiver(track, transceiverInit)

        dataChannel = connection.createDataChannel("oai-events", DataChannel.Init())

        val offerConstraints = MediaConstraints().apply {
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "false"))
        }

        Log.i(TAG, "start: creating offer")
        val offer = try {
            createOffer(connection, offerConstraints)
        } catch (t: Throwable) {
            Log.e(TAG, "start: createOffer failed", t)
            cleanup()
            throw t
        }

        Log.i(TAG, "start: setting local description")
        try {
            setLocalDescription(connection, offer)
        } catch (t: Throwable) {
            Log.e(TAG, "start: setLocalDescription failed", t)
            cleanup()
            throw t
        }

        Log.i(TAG, "start: awaiting ICE gathering complete")
        val iceGatheringCompleted = withTimeoutOrNull(REALTIME_ICE_GATHERING_TIMEOUT_MS) {
            awaitIceGatheringComplete(connection)
            true
        } == true
        if (!iceGatheringCompleted) {
            // A host candidate is normally present by now. Prefer sending the
            // best available offer to hanging the entire realtime start flow.
            Log.w(TAG, "start: ICE gathering timed out; using current local description")
        }

        if (isClosed.get() || peerConnection !== connection) {
            Log.w(TAG, "start: session closed while awaiting ICE gathering")
            throw RealtimeWebRtcSessionException("session stopped before local description was ready")
        }

        val localSdp = connection.localDescription?.description
            ?: run {
                Log.e(TAG, "start: local description unavailable after ICE gathering")
                cleanup()
                throw RealtimeWebRtcSessionException("local description unavailable after ICE gathering")
            }
        Log.i(TAG, "start: offer ready (${localSdp.length} bytes)")
        return localSdp
    }

    suspend fun applyAnswer(sdp: String) {
        val connection = peerConnection
            ?: throw RealtimeWebRtcSessionException("cannot apply answer: session not started")
        Log.i(TAG, "applyAnswer: setting remote description (${sdp.length} bytes)")
        setRemoteDescription(connection, SessionDescription(SessionDescription.Type.ANSWER, sdp))
        Log.i(TAG, "applyAnswer: remote description applied")
    }

    fun stop() {
        Log.i(TAG, "stop: closing peer connection")
        cleanup()
    }

    private fun cleanup() {
        isClosed.set(true)
        iceGatheringContinuation?.let {
            iceGatheringContinuation = null
            if (it.isActive) it.resume(Unit)
        }
        try {
            dataChannel?.close()
        } catch (t: Throwable) {
            Log.w(TAG, "dataChannel.close failed: ${t.message}")
        }
        dataChannel?.dispose()
        dataChannel = null
        audioTrack = null
        audioSource?.dispose()
        audioSource = null
        try {
            peerConnection?.close()
        } catch (t: Throwable) {
            Log.w(TAG, "peerConnection.close failed: ${t.message}")
        }
        peerConnection?.dispose()
        peerConnection = null
        releaseAudio()
    }

    private fun configureAudio() {
        if (!didConfigureAudio.compareAndSet(false, true)) return
        previousAudioMode = audioManager.mode
        previousSpeakerphoneOn = audioManager.isSpeakerphoneOn

        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener { }
                .build()
            audioFocusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                null,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
            )
        }

        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        audioManager.isSpeakerphoneOn = true
    }

    private fun releaseAudio() {
        if (!didConfigureAudio.compareAndSet(true, false)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(null)
        }
        audioManager.mode = previousAudioMode
        audioManager.isSpeakerphoneOn = previousSpeakerphoneOn
    }

    private suspend fun createOffer(
        connection: PeerConnection,
        constraints: MediaConstraints
    ): SessionDescription = suspendCancellableCoroutine { cont ->
        connection.createOffer(object : SdpObserver {
            override fun onCreateSuccess(description: SessionDescription) {
                if (cont.isActive) cont.resume(description)
            }

            override fun onCreateFailure(reason: String?) {
                if (cont.isActive) cont.resumeWithException(
                    RealtimeWebRtcSessionException("createOffer failed: $reason")
                )
            }

            override fun onSetSuccess() {}
            override fun onSetFailure(reason: String?) {}
        }, constraints)
    }

    private suspend fun setLocalDescription(
        connection: PeerConnection,
        description: SessionDescription
    ): Unit = suspendCancellableCoroutine { cont ->
        connection.setLocalDescription(object : SdpObserver {
            override fun onCreateSuccess(description: SessionDescription) {}
            override fun onCreateFailure(reason: String?) {}
            override fun onSetSuccess() {
                if (cont.isActive) cont.resume(Unit)
            }

            override fun onSetFailure(reason: String?) {
                if (cont.isActive) cont.resumeWithException(
                    RealtimeWebRtcSessionException("setLocalDescription failed: $reason")
                )
            }
        }, description)
    }

    private suspend fun setRemoteDescription(
        connection: PeerConnection,
        description: SessionDescription
    ): Unit = suspendCancellableCoroutine { cont ->
        connection.setRemoteDescription(object : SdpObserver {
            override fun onCreateSuccess(description: SessionDescription) {}
            override fun onCreateFailure(reason: String?) {}
            override fun onSetSuccess() {
                if (cont.isActive) cont.resume(Unit)
            }

            override fun onSetFailure(reason: String?) {
                if (cont.isActive) cont.resumeWithException(
                    RealtimeWebRtcSessionException("setRemoteDescription failed: $reason")
                )
            }
        }, description)
    }

    private suspend fun awaitIceGatheringComplete(connection: PeerConnection) {
        if (connection.iceGatheringState() == PeerConnection.IceGatheringState.COMPLETE) return
        suspendCancellableCoroutine<Unit> { cont ->
            iceGatheringContinuation = cont
            cont.invokeOnCancellation { iceGatheringContinuation = null }
        }
    }

    private fun onIceGatheringState(state: PeerConnection.IceGatheringState) {
        Log.i(TAG, "onIceGatheringChange: $state")
        if (state != PeerConnection.IceGatheringState.COMPLETE) return
        val cont = iceGatheringContinuation ?: return
        iceGatheringContinuation = null
        if (cont.isActive) cont.resume(Unit)
    }

    private inner class DelegateAdapter : PeerConnection.Observer {
        override fun onSignalingChange(newState: PeerConnection.SignalingState) {
            Log.i(TAG, "onSignalingChange: $newState")
        }

        override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState) {
            Log.i(TAG, "onIceConnectionChange: $newState")
        }

        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState) {
            onIceGatheringState(newState)
        }

        override fun onIceCandidate(candidate: IceCandidate) {}
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) {}
        override fun onAddStream(stream: MediaStream) {}
        override fun onRemoveStream(stream: MediaStream) {}
        override fun onDataChannel(channel: DataChannel) {
            Log.i(TAG, "onDataChannel: ${channel.label()}")
        }

        override fun onRenegotiationNeeded() {}
        override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) {
            Log.i(TAG, "onAddTrack: streams=${streams.size}")
        }
    }

    companion object {
        private const val TAG = "RealtimeWebRtc"

        @Volatile
        private var sharedFactoryInstance: PeerConnectionFactory? = null

        @Volatile
        private var sharedEglBase: EglBase? = null

        private fun sharedFactory(context: Context): PeerConnectionFactory {
            val existing = sharedFactoryInstance
            if (existing != null) return existing
            return synchronized(this) {
                val again = sharedFactoryInstance
                if (again != null) return@synchronized again
                PeerConnectionFactory.initialize(
                    PeerConnectionFactory.InitializationOptions
                        .builder(context.applicationContext)
                        .createInitializationOptions()
                )
                val egl = EglBase.create()
                sharedEglBase = egl
                val adm = JavaAudioDeviceModule.builder(context.applicationContext)
                    .setUseHardwareAcousticEchoCanceler(true)
                    .setUseHardwareNoiseSuppressor(true)
                    .createAudioDeviceModule()
                val factory = PeerConnectionFactory.builder()
                    .setAudioDeviceModule(adm)
                    .setVideoEncoderFactory(DefaultVideoEncoderFactory(egl.eglBaseContext, true, true))
                    .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl.eglBaseContext))
                    .createPeerConnectionFactory()
                sharedFactoryInstance = factory
                factory
            }
        }
    }
}
