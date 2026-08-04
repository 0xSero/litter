package com.litter.android.voice

import org.junit.Assert.assertEquals
import org.junit.Test
import org.webrtc.PeerConnection

class RealtimeWebRtcSessionTest {

    @Test
    fun peerConnectionUsesBoundedSinglePassIceGathering() {
        val configuration = realtimePeerConnectionConfiguration()

        assertEquals(PeerConnection.SdpSemantics.UNIFIED_PLAN, configuration.sdpSemantics)
        assertEquals(
            PeerConnection.ContinualGatheringPolicy.GATHER_ONCE,
            configuration.continualGatheringPolicy,
        )
        assertEquals(5_000L, REALTIME_ICE_GATHERING_TIMEOUT_MS)
    }
}
