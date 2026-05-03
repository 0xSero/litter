import AVFoundation
import Foundation
import WebRTC

enum RealtimeWebRtcSessionError: Error {
    case peerConnectionCreationFailed
    case offerCreationFailed
    case localDescriptionUnavailable
    case sessionAlreadyStarted
    case sessionNotStarted
}

@MainActor
final class RealtimeWebRtcSession: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
    }()

    private static let iceGatheringTimeout: Duration = .seconds(5)

    var onRouteChanged: ((VoiceSessionAudioRoute) -> Void)?

    private let delegateAdapter = DelegateAdapter()
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var audioTrack: RTCAudioTrack?
    private var didConfigureAudioSession = false
    private var speakerModeEnabled = true
    private var routeObserver: NSObjectProtocol?
    private var candidatesGathered = 0

    private var iceGatheringContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        delegateAdapter.owner = self
    }

    func start() async throws -> String {
        LLog.info("webrtc", "session.start entry")
        guard peerConnection == nil else {
            LLog.warn("webrtc", "session.start called while already started")
            throw RealtimeWebRtcSessionError.sessionAlreadyStarted
        }

        configureAudioSession()
        installRouteObserver()
        LLog.info("webrtc", "audio session configured")

        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: delegateAdapter) else {
            LLog.error("webrtc", "peer connection creation failed")
            removeRouteObserver()
            deactivateAudioSessionIfNeeded()
            throw RealtimeWebRtcSessionError.peerConnectionCreationFailed
        }
        self.peerConnection = connection
        LLog.info("webrtc", "peer connection created")

        let audioSource = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = Self.factory.audioTrack(with: audioSource, trackId: "realtime-audio")
        self.audioTrack = track

        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendRecv
        connection.addTransceiver(with: track, init: transceiverInit)

        let dataConfig = RTCDataChannelConfiguration()
        dataConfig.isOrdered = true
        self.dataChannel = connection.dataChannel(forLabel: "oai-events", configuration: dataConfig)

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": kRTCMediaConstraintsValueTrue,
                "OfferToReceiveVideo": kRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil
        )
        let offer: RTCSessionDescription
        do {
            offer = try await createOffer(connection: connection, constraints: offerConstraints)
            LLog.info("webrtc", "offer created", fields: ["sdp_len": offer.sdp.count])
        } catch {
            LLog.error("webrtc", "offer creation failed", error: error)
            cleanup()
            throw error
        }

        do {
            try await setLocalDescription(connection: connection, description: offer)
            LLog.info("webrtc", "local description set")
        } catch {
            LLog.error("webrtc", "setLocalDescription failed", error: error)
            cleanup()
            throw error
        }

        LLog.info("webrtc", "awaiting ICE gathering complete")
        let timedOut = await awaitIceGatheringComplete(connection: connection)
        if timedOut {
            LLog.warn(
                "webrtc",
                "ICE gathering timed out; sending partial offer",
                fields: ["candidates_gathered": candidatesGathered]
            )
        } else {
            LLog.info(
                "webrtc",
                "ICE gathering complete",
                fields: ["candidates_gathered": candidatesGathered]
            )
        }

        guard let final = connection.localDescription?.sdp else {
            LLog.error("webrtc", "local description unavailable after gathering")
            cleanup()
            throw RealtimeWebRtcSessionError.localDescriptionUnavailable
        }
        LLog.info("webrtc", "session.start success", fields: ["sdp_len": final.count])
        emitRoute()
        return final
    }

    func applyAnswer(_ sdp: String) async throws {
        LLog.info("webrtc", "applyAnswer entry", fields: ["sdp_len": sdp.count])
        guard let connection = peerConnection else {
            LLog.error("webrtc", "applyAnswer called without active session")
            throw RealtimeWebRtcSessionError.sessionNotStarted
        }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        do {
            try await setRemoteDescription(connection: connection, description: answer)
            LLog.info("webrtc", "applyAnswer success")
        } catch {
            LLog.error("webrtc", "applyAnswer failed", error: error)
            throw error
        }
    }

    func stop() {
        LLog.info("webrtc", "session.stop entry")
        cleanup()
    }

    func toggleSpeaker() throws {
        guard peerConnection != nil else { return }
        let route = currentRoute()
        guard route.supportsSpeakerToggle else { return }
        speakerModeEnabled.toggle()
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try session.overrideOutputAudioPort(speakerModeEnabled ? .speaker : .none)
        emitRoute()
    }

    /// Toggle the local mic track without renegotiating the peer
    /// connection. Disabling the track stops Codex from receiving any
    /// audio frames; re-enabling resumes immediately.
    func setMicrophoneMuted(_ muted: Bool) {
        audioTrack?.isEnabled = !muted
    }

    private func cleanup() {
        if let continuation = iceGatheringContinuation {
            iceGatheringContinuation = nil
            continuation.resume()
        }
        removeRouteObserver()
        dataChannel?.close()
        dataChannel = nil
        audioTrack = nil
        peerConnection?.close()
        peerConnection = nil
        speakerModeEnabled = true
        candidatesGathered = 0
        deactivateAudioSessionIfNeeded()
    }

    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .defaultToSpeaker]
            )
            try session.setActive(true)
            didConfigureAudioSession = true
        } catch {
            LLog.error("webrtc", "failed to configure RTC audio session", error: error)
        }
    }

    private func deactivateAudioSessionIfNeeded() {
        guard didConfigureAudioSession else { return }
        didConfigureAudioSession = false
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setActive(false)
        } catch {
            LLog.warn("webrtc", "failed to deactivate RTC audio session: \(error.localizedDescription)")
        }
    }

    private func installRouteObserver() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emitRoute() }
        }
    }

    private func removeRouteObserver() {
        if let observer = routeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeObserver = nil
        }
    }

    private func emitRoute() {
        onRouteChanged?(currentRoute())
    }

    private func currentRoute() -> VoiceSessionAudioRoute {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let name = output?.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = (name?.isEmpty == false ? name! : "Audio")

        switch output?.portType {
        case .builtInSpeaker:
            return .speaker
        case .builtInReceiver:
            return .receiver
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return .bluetooth(fallbackName)
        case .headphones, .headsetMic, .usbAudio:
            return .headphones(fallbackName)
        case .carAudio:
            return .carPlay(fallbackName)
        case .airPlay:
            return .airPlay(fallbackName)
        default:
            return .unknown(fallbackName)
        }
    }

    private func createOffer(
        connection: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { description, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let description = description else {
                    continuation.resume(throwing: RealtimeWebRtcSessionError.offerCreationFailed)
                    return
                }
                continuation.resume(returning: description)
            }
        }
    }

    private func setLocalDescription(
        connection: RTCPeerConnection,
        description: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func setRemoteDescription(
        connection: RTCPeerConnection,
        description: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Returns true when the wait completed via timeout (gathering may still
    /// be in progress); false when ICE reported `.complete` first.
    private func awaitIceGatheringComplete(connection: RTCPeerConnection) async -> Bool {
        if connection.iceGatheringState == .complete { return false }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return false }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.iceGatheringContinuation = continuation
                }
                return false
            }
            group.addTask { [weak self] in
                try? await Task.sleep(for: Self.iceGatheringTimeout)
                await MainActor.run {
                    if let continuation = self?.iceGatheringContinuation {
                        self?.iceGatheringContinuation = nil
                        continuation.resume()
                    }
                }
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    fileprivate func iceGatheringStateChanged(to state: RTCIceGatheringState) {
        LLog.info("webrtc", "iceGatheringState changed", fields: ["state": describe(state)])
        guard state == .complete, let continuation = iceGatheringContinuation else { return }
        iceGatheringContinuation = nil
        continuation.resume()
    }

    fileprivate func iceConnectionStateChanged(to state: RTCIceConnectionState) {
        LLog.info("webrtc", "iceConnectionState changed", fields: ["state": describe(state)])
    }

    fileprivate func signalingStateChanged(to state: RTCSignalingState) {
        LLog.info("webrtc", "signalingState changed", fields: ["state": describe(state)])
    }

    fileprivate func didGenerateCandidate() {
        candidatesGathered += 1
        LLog.debug("webrtc", "ice candidate gathered", fields: ["count": candidatesGathered])
    }

    private func describe(_ state: RTCIceGatheringState) -> String {
        switch state {
        case .new: return "new"
        case .gathering: return "gathering"
        case .complete: return "complete"
        @unknown default: return "unknown"
        }
    }

    private func describe(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "unknown"
        }
    }

    private func describe(_ state: RTCSignalingState) -> String {
        switch state {
        case .stable: return "stable"
        case .haveLocalOffer: return "haveLocalOffer"
        case .haveLocalPrAnswer: return "haveLocalPrAnswer"
        case .haveRemoteOffer: return "haveRemoteOffer"
        case .haveRemotePrAnswer: return "haveRemotePrAnswer"
        case .closed: return "closed"
        @unknown default: return "unknown"
        }
    }
}

private final class DelegateAdapter: NSObject, RTCPeerConnectionDelegate {
    weak var owner: RealtimeWebRtcSession?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        let owner = self.owner
        Task { @MainActor in owner?.signalingStateChanged(to: stateChanged) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let owner = self.owner
        Task { @MainActor in owner?.iceConnectionStateChanged(to: newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        let owner = self.owner
        Task { @MainActor in owner?.iceGatheringStateChanged(to: newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let owner = self.owner
        Task { @MainActor in owner?.didGenerateCandidate() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
