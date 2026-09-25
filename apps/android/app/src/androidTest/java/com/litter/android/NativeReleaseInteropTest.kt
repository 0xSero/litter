package com.litter.android

import android.graphics.PixelFormat
import android.media.ImageReader
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.litter.android.core.bridge.GhosttyInputCallback
import com.litter.android.core.bridge.GhosttyRendererBridge
import com.litter.android.core.bridge.GhosttyWakeupListener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Run against the optimized release target; Debug does not validate R8 rules. */
@RunWith(AndroidJUnit4::class)
class NativeReleaseInteropTest {
    @Test
    fun webRtcCreatesLocalOfferThroughNativeCallback() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context)
                .createInitializationOptions(),
        )
        val options = PeerConnectionFactory.Options().apply {
            disableNetworkMonitor = true
            networkIgnoreMask = PeerConnectionFactory.Options.ADAPTER_TYPE_ANY
        }
        val factory = PeerConnectionFactory.builder().setOptions(options).createPeerConnectionFactory()
        try {
            val configuration = PeerConnection.RTCConfiguration(java.util.Collections.emptyList()).apply {
                sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            }
            val connection = requireNotNull(factory.createPeerConnection(configuration, EmptyObserver()))
            try {
                val channel = requireNotNull(connection.createDataChannel("interop", DataChannel.Init()))
                try {
                    val completed = CountDownLatch(1)
                    val offer = AtomicReference<SessionDescription>()
                    val failure = AtomicReference<String>()
                    connection.createOffer(object : SdpObserver {
                        override fun onCreateSuccess(description: SessionDescription) {
                            offer.set(description)
                            completed.countDown()
                        }
                        override fun onCreateFailure(reason: String?) {
                            failure.set("Native offer callback reported failure")
                            completed.countDown()
                        }
                        override fun onSetSuccess() = Unit
                        override fun onSetFailure(reason: String?) = Unit
                    }, MediaConstraints())
                    assertTrue("Native SDP callback was not delivered", completed.await(10, TimeUnit.SECONDS))
                    assertNull(failure.get())
                    val description = requireNotNull(offer.get())
                    assertEquals("OFFER", description.type.name)
                    assertTrue("Native offer must include SDP", description.description.length > 0)
                    // No media tracks or setLocalDescription: no recording,
                    // camera, ICE gathering, remote peer, or network exchange.
                } finally {
                    try { channel.close() } finally { channel.dispose() }
                }
            } finally {
                try { connection.close() } finally { connection.dispose() }
            }
        } finally {
            factory.dispose()
        }
    }

    @Test
    fun ghosttyLoadsNativeLibraryAndPreservesCallbackSignatures() {
        val status = GhosttyRendererBridge.status()
        assertTrue("Ghostty native libraries must load", status.libraryLoaded)
        assertTrue("Ghostty version JNI call must return a value", (status.version?.length ?: 0) > 0)
        assertEquals(Void.TYPE, GhosttyInputCallback::class.java.getMethod("onInput", ByteArray::class.java).returnType)
        assertEquals(Void.TYPE, GhosttyWakeupListener::class.java.getMethod("onWakeup").returnType)
    }

    @Test
    fun ghosttySurfaceDeliversInputAndClosesWhenRendererIsSupported() {
        // ImageReader supplies a native window without launching an Activity.
        // Current GLES-only emulators cannot create Ghostty's GL4.3 surface;
        // report a skipped surface test rather than claiming callback coverage.
        val reader = ImageReader.newInstance(64, 64, PixelFormat.RGBA_8888, 2)
        try {
            val surface = GhosttyRendererBridge.createSurface(reader.surface, 64, 64, 1f, 13f)
            assumeNotNull(surface)
            val renderer = requireNotNull(surface)
            try {
                val input = AtomicReference<ByteArray>()
                val received = CountDownLatch(1)
                renderer.setInputCallback(GhosttyInputCallback { bytes ->
                    input.set(bytes)
                    received.countDown()
                })
                renderer.setWakeupListener(GhosttyWakeupListener { })
                renderer.sendText("r8-interop")
                assertTrue("Ghostty native input callback was not delivered", received.await(5, TimeUnit.SECONDS))
                assertNotNull(input.get())
                assertTrue(input.get().size > 0)
            } finally {
                renderer.close()
            }
        } finally {
            reader.close()
        }
    }

    private class EmptyObserver : PeerConnection.Observer {
        override fun onSignalingChange(state: PeerConnection.SignalingState) = Unit
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) = Unit
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) = Unit
        override fun onIceCandidate(candidate: IceCandidate) = Unit
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) = Unit
        override fun onAddStream(stream: MediaStream) = Unit
        override fun onRemoveStream(stream: MediaStream) = Unit
        override fun onDataChannel(channel: DataChannel) = Unit
        override fun onRenegotiationNeeded() = Unit
    }
}
