#if !targetEnvironment(macCatalyst)
import Foundation
import NearbyInteraction
import Observation
import UIKit
import simd

/// A resolved local-network endpoint advertised by the Mac pairing host.
struct BonjourDiscoverySeed: Hashable {
    let name: String
    let host: String
    let port: UInt16?
    let serviceType: String
}

/// The Bonjour browser used by the iPhone pairing flow. This intentionally
/// owns only `_litter-pair._tcp.` discovery; general Codex/SSH network scanning
/// is no longer part of the Add Server interface.
@MainActor
final class BonjourServiceDiscoverer: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private struct ServiceRecord {
        let name: String
        let port: UInt16?
    }

    private let serviceType: String
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var results: [String: ServiceRecord] = [:]
    private var pendingServices: Set<ObjectIdentifier> = []
    private var continuation: CheckedContinuation<[BonjourDiscoverySeed], Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resolveDrainTask: Task<Void, Never>?
    private var isFinished = false
    private var requestedStop = false

    init(serviceType: String) {
        self.serviceType = serviceType
    }

    func discover(timeout: TimeInterval) async -> [BonjourDiscoverySeed] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: serviceType, inDomain: "local.")
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                let nanos = UInt64(max(timeout, 0.25) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                self.stopAndDrain()
            }
        }
    }

    private func stopAndDrain() {
        guard !requestedStop else { return }
        requestedStop = true
        browser.stop()
        if pendingServices.isEmpty {
            finish()
            return
        }
        resolveDrainTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(900))
            self.finish()
        }
    }

    private func finish() {
        // Consume the continuation before stopping delegates: browser.stop()
        // can synchronously re-enter didStopSearch.
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        isFinished = true
        timeoutTask?.cancel()
        resolveDrainTask?.cancel()
        timeoutTask = nil
        resolveDrainTask = nil
        if !requestedStop {
            browser.stop()
        }
        for service in services {
            service.stop()
            service.delegate = nil
        }
        let discovered = results.map {
            BonjourDiscoverySeed(
                name: $0.value.name,
                host: $0.key,
                port: $0.value.port,
                serviceType: serviceType
            )
        }
        continuation.resume(returning: discovered)
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {}

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        if requestedStop, pendingServices.isEmpty {
            finish()
        } else if !requestedStop {
            finish()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !isFinished else { return }
        services.append(service)
        pendingServices.insert(ObjectIdentifier(service))
        service.delegate = self
        service.resolve(withTimeout: 2.5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        pendingServices.remove(ObjectIdentifier(sender))
        guard let addresses = sender.addresses else { return }
        let resolvedPort: UInt16? = {
            guard sender.port > 0, sender.port <= Int(UInt16.max) else { return nil }
            return UInt16(sender.port)
        }()
        for address in addresses {
            guard let ip = Self.ipv4Address(fromSockaddrData: address) else { continue }
            results[ip] = ServiceRecord(name: sender.name, port: resolvedPort)
            break
        }
        if requestedStop, pendingServices.isEmpty {
            finish()
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pendingServices.remove(ObjectIdentifier(sender))
        if requestedStop, pendingServices.isEmpty {
            finish()
        }
    }

    private static func ipv4Address(fromSockaddrData data: Data) -> String? {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            let sockaddrPointer = base.assumingMemoryBound(to: sockaddr.self)
            guard sockaddrPointer.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            let ipv4Pointer = base.assumingMemoryBound(to: sockaddr_in.self)
            var address = ipv4Pointer.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
    }
}

enum NearbyMacPairingState: Equatable {
    case searching
    case connecting
    case handshaking
    case awaitingConfirm
    case paired
    case rejected
    case failed
}

/// iOS-only first-launch onboarding: browse for a nearby `_litter-pair._tcp.`
/// service, open a WebSocket pair session via Rust, run NISession against
/// the Mac's NI discovery token, and save a SavedServer on accept. Runs
/// only when SavedServerStore has no user-remembered servers. The class
/// is single-shot: each attempt runs a fresh instance via `start()`.
///
/// Wiring: platform (Swift) owns Bonjour browse + NISession; Rust owns the
/// pair protocol state machine and reports transitions through a polled
/// event stream. We re-expose state as an `@Observable` so SwiftUI can
/// render the onboarding view directly.
@MainActor
@Observable
final class NearbyMacPairing: NSObject {
    static let shared = NearbyMacPairing()

    /// Bonjour service type we advertise on and browse for pairing.
    private static let pairServiceType = "_litter-pair._tcp."
    /// How long to browse for a pair service before showing a "couldn't
    /// find" fallback UI.
    private static let browseTimeout: TimeInterval = 20
    /// Distance threshold (meters, NI-derived) at which we auto-send
    /// pair_request. Only fires when both peers have UWB and `NISession`
    /// produces real readings; otherwise BLE proximity is the trigger.
    private static let pairDistanceThreshold: Float = 1.0
    /// Upper bound on the entire onboarding flow before we treat it as a
    /// timeout and let the user fall back to manual discovery.
    private static let flowTimeout: TimeInterval = 60

    // MARK: - Public observable state

    var state: NearbyMacPairingState = .searching
    var discoveredMacName: String?
    var lastDistance: Float?
    var lastDirection: simd_float3?
    var lastHorizontalAngle: Float?
    var lastUpdate: Date?
    var isRunning: Bool = false
    /// When true, suppress the auto pair_request submission so we can stay
    /// in the ranging state indefinitely for debugging UWB/BLE readings.
    var debugMode: Bool = false

    /// BLE-derived proximity state, exposed for the debug view. The scanner
    /// runs whenever the flow is active, regardless of UWB capability — it's
    /// the actual proximity signal on Macs (which all lack a U1/U2 chip).
    var lastRssi: Int?
    var smoothedRssi: Float?
    var bleProximity: PairBLE.Bucket = .unknown
    var bleEstimatedDistance: Double?

    /// Ultrasonic Doppler velocity (m/s, positive = approaching the Mac).
    /// Smoothed via EMA in `UltrasonicReader`. Updates ~12 Hz when the
    /// 19 kHz carrier is detectable.
    var dopplerVelocityMS: Float?
    /// Detected ultrasonic peak frequency in Hz, or nil when below the
    /// detection threshold (Mac out of acoustic range).
    var ultrasonicPeakHz: Float?
    /// Confidence proxy in [0, ~10ish]; >2 means the carrier is clearly
    /// audible to the iPhone mic.
    var ultrasonicConfidence: Float?

    /// Set when pair_accept arrives. Consumed by `LitterApp`/ContentView to
    /// open a connection and dismiss onboarding.
    var completedServer: SavedServer?

    // MARK: - Internals

    private let appClient = AppClient()
    private var browser: BonjourServiceDiscoverer?
    private var browseTask: Task<Void, Never>?
    private var flowTimeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pairClient: PairClientHandle?
    private var niSession: NISession?
    private var niDelegateBox: NIDelegateBox?
    private var pendingMacDiscoveryToken: NIDiscoveryToken?
    private var bleScanner: PairBLEScanner?
    private var bleTrackers: [UUID: PairBLEPeerTracker] = [:]
    private var bleStrongestPeer: UUID?
    private var ultrasonicReader: UltrasonicReader?
    private var lastDistanceRelayAt: Date = .distantPast
    private var didSendPairRequest = false
    private var deviceName: String = UIDevice.current.name
    private weak var appModel: AppModel?

    override private init() {
        super.init()
    }

    /// Start the onboarding flow. Idempotent while running. No-op if the
    /// user already has remembered servers. Runs on every iPhone — UWB is
    /// optional now that BLE proximity covers Macs without a U1/U2 chip.
    func startIfNeeded(appModel: AppModel) {
        guard !isRunning else { return }
        guard SavedServerStore.rememberedServers().isEmpty else {
            LLog.info("pair", "skipping onboarding, user already has remembered servers")
            return
        }
        self.appModel = appModel
        isRunning = true
        debugMode = false
        resetTransientState()
        startFlowTimeout()
        startBrowse()
        startBLEScan()
        startUltrasonicReader()
    }

    /// Debug-only entry point. Browses for the Mac pair host and runs the
    /// same NISession + BLE proximity stack the onboarding flow uses, but
    /// skips the auto pair_request submission so the iPhone keeps streaming
    /// distance/RSSI updates indefinitely. Bypasses the saved-server gate.
    func startForDebug() {
        teardown()
        isRunning = true
        debugMode = true
        resetTransientState()
        startBrowse()
        startBLEScan()
        startUltrasonicReader()
    }

    /// Public entry point for the "Pair" feature surfaced in Settings →
    /// Experimental. Same as `startIfNeeded` but skips the saved-server
    /// gate so users can re-pair after they already have remembered
    /// servers. Auto-pair trigger is enabled (debugMode=false).
    func startPairing(appModel: AppModel) {
        guard !isRunning else { return }
        self.appModel = appModel
        isRunning = true
        debugMode = false
        resetTransientState()
        startFlowTimeout()
        startBrowse()
        startBLEScan()
        startUltrasonicReader()
    }

    /// Stop the debug session and reset state.
    func stopDebug() {
        isRunning = false
        debugMode = false
        teardown()
        state = .searching
        resetTransientState()
    }

    private func resetTransientState() {
        state = .searching
        discoveredMacName = nil
        lastDistance = nil
        lastDirection = nil
        lastHorizontalAngle = nil
        lastUpdate = nil
        lastRssi = nil
        smoothedRssi = nil
        bleProximity = .unknown
        bleEstimatedDistance = nil
        dopplerVelocityMS = nil
        ultrasonicPeakHz = nil
        ultrasonicConfidence = nil
        completedServer = nil
        didSendPairRequest = false
        bleTrackers.removeAll()
        bleStrongestPeer = nil
        lastDistanceRelayAt = .distantPast
    }

    /// User tapped "Skip" / "Set up manually" — stop everything and let
    /// ContentView dismiss the onboarding sheet.
    func cancel() {
        isRunning = false
        teardown()
    }

    /// Retry after a rejected or failed attempt. Same entry point as
    /// `startIfNeeded` but without the remembered-server check.
    func retry() {
        guard appModel != nil else { return }
        teardown()
        debugMode = false
        isRunning = true
        resetTransientState()
        startFlowTimeout()
        startBrowse()
        startBLEScan()
        startUltrasonicReader()
    }

    // MARK: - Browse

    private func startBrowse() {
        let browser = BonjourServiceDiscoverer(serviceType: Self.pairServiceType)
        self.browser = browser
        browseTask = Task { @MainActor [weak self] in
            let seeds = await browser.discover(timeout: Self.browseTimeout)
            guard let self, self.isRunning else { return }
            self.browser = nil
            // Pick the first responsive pair service. The Mac only
            // advertises a single service per process.
            guard let pick = seeds.first(where: { $0.port != nil }) else {
                LLog.info("pair", "no pair service seen within timeout")
                self.state = .failed
                return
            }
            self.discoveredMacName = pick.name
            LLog.info(
                "pair",
                "pair service discovered",
                fields: [
                    "name": pick.name,
                    "host": pick.host,
                    "port": Int(pick.port ?? 0)
                ]
            )
            self.connectAndHandshake(host: pick.host, port: pick.port ?? 0)
        }
    }

    // MARK: - WS connect + NI exchange

    private func connectAndHandshake(host: String, port: UInt16) {
        state = .connecting
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            do {
                // Try to spin up NISession so we can ship a discovery token.
                // If this device or the Mac lacks UWB, the token is empty
                // and the Rust pair host knows to skip ranging — BLE is the
                // proximity signal in that case.
                let tokenB64 = self.prepareNISession()

                let client = try await self.appClient.pairFromIphone(
                    host: host,
                    port: port,
                    deviceName: self.deviceName,
                    niDiscoveryTokenB64: tokenB64
                )
                // User may have cancelled while we were awaiting the
                // connection; drop the just-opened client on the floor
                // instead of leaving it orphaned.
                guard self.isRunning else {
                    Task { await client.stop() }
                    return
                }
                self.pairClient = client
                self.state = .handshaking
                self.startEventPoll()
            } catch {
                LLog.error("pair", "pair_from_iphone failed", error: error)
                self.state = .failed
            }
        }
    }

    private func startEventPoll() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, let client = self.pairClient {
                if let event = await client.pollEvent() {
                    self.handle(event: event)
                } else {
                    // No event — sleep 80ms to avoid spinning.
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            }
        }
    }

    private func handle(event: PairEvent) {
        switch event {
        case let .clientPeerAccepted(niDiscoveryTokenB64):
            handleMacNIToken(b64: niDiscoveryTokenB64)
        case let .clientPairAccepted(codexWsUrl, lanIp):
            handlePairAccepted(codexWsUrl: codexWsUrl, lanIp: lanIp)
        case .peerRejected:
            state = .rejected
            isRunning = false
        case let .disconnected(reason):
            LLog.info("pair", "disconnected", fields: ["reason": reason])
            if state != .paired, state != .rejected, state != .failed {
                state = .failed
                isRunning = false
            }
        case .hostPeerConnected, .hostPairRequest, .distanceUpdate:
            // Host-side events; iPhone ignores.
            break
        }
    }

    /// Spin up a local NISession so we can ship a discovery token in the
    /// pair_hello. Returns the base64-encoded token, or an empty string when
    /// this device has no UWB radio. The Rust pair host accepts empty tokens
    /// and downgrades to "no NI ranging" — BLE proximity still gates pair.
    private func prepareNISession() -> String {
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            LLog.info("pair", "NISession unsupported on this iPhone — relying on BLE proximity")
            return ""
        }
        let session = NISession()
        let delegate = NIDelegateBox { [weak self] obj in
            Task { @MainActor in self?.handleNIUpdate(obj) }
        } invalidated: { [weak self] err in
            Task { @MainActor in self?.handleNIInvalidated(err) }
        }
        session.delegate = delegate
        niDelegateBox = delegate
        niSession = session
        guard let token = session.discoveryToken,
              let encoded = try? encodeDiscoveryToken(token)
        else {
            LLog.warn("pair", "NISession produced no discovery token — relying on BLE proximity")
            return ""
        }
        return encoded
    }

    private func handleMacNIToken(b64: String) {
        // Empty/missing token is the expected case for current Macs (no
        // U1/U2 on any shipping Mac); BLE proximity is the trigger then.
        guard !b64.isEmpty, let session = niSession else {
            if state == .handshaking {
                LLog.info("pair", "no NI ranging — BLE proximity is the trigger")
            }
            return
        }
        guard let tokenData = Data(base64Encoded: b64), !tokenData.isEmpty,
              let macToken = decodeDiscoveryToken(tokenData)
        else {
            LLog.warn("pair", "mac NI discovery token undecodable; falling back to BLE-only proximity")
            return
        }
        pendingMacDiscoveryToken = macToken
        let config = NINearbyPeerConfiguration(peerToken: macToken)
        session.run(config)
        LLog.info("pair", "NISession started against mac token")
    }

    private func handleNIUpdate(_ object: NINearbyObject?) {
        let distance = object?.distance
        lastDistance = distance
        lastDirection = object?.direction
        if #available(iOS 16.0, *) {
            lastHorizontalAngle = object?.horizontalAngle
        }
        lastUpdate = Date()
        if let distance {
            // Fire-and-forget distance ping for the Mac UI affordance.
            try? pairClient?.submitNiDistance(distanceM: distance)
            if distance <= Self.pairDistanceThreshold {
                triggerPairRequest(reason: "ni_distance", distance: distance)
            }
        }
    }

    private func handleNIInvalidated(_ error: Error) {
        LLog.warn("pair", "NISession invalidated", fields: ["error": String(describing: error)])
        // BLE proximity can still drive the pair trigger — only fail the
        // flow if we have no fallback signal in flight.
        niSession = nil
        niDelegateBox = nil
    }

    // MARK: - BLE proximity scan

    private func startBLEScan() {
        guard bleScanner == nil else { return }
        let scanner = PairBLEScanner()
        bleScanner = scanner
        scanner.start { [weak self] peripheralId, _, rssi in
            self?.handleBLESample(peripheralId: peripheralId, rssi: rssi)
        }
    }

    private func handleBLESample(peripheralId: UUID, rssi: Int) {
        guard isRunning else { return }
        let tracker = bleTrackers[peripheralId] ?? PairBLEPeerTracker()
        tracker.record(rssi: rssi)
        bleTrackers[peripheralId] = tracker

        // Track the strongest peer for the debug UI; assume the strongest
        // BLE advertiser is the same Mac the user is trying to pair with.
        let strongest = bleTrackers.max { lhs, rhs in
            (lhs.value.lastRssi ?? Int.min) < (rhs.value.lastRssi ?? Int.min)
        }
        if let strongest {
            bleStrongestPeer = strongest.key
            lastRssi = strongest.value.lastRssi
            smoothedRssi = strongest.value.smoothedRssi
            bleProximity = PairBLE.Bucket.from(rssi: strongest.value.lastRssi)
            bleEstimatedDistance = strongest.value.lastRssi.flatMap { PairBLE.estimateDistanceMeters(rssi: $0) }
        }

        // Relay BLE-derived distance to the Mac when NI ranging isn't
        // producing readings (which is always, on current Macs). Throttled
        // to 5 Hz so we don't spam the WS pair channel; that's plenty for
        // the Mac's pulse animation.
        if lastDistance == nil, let est = bleEstimatedDistance {
            relayDistanceIfNeeded(distanceM: Float(est))
        }

        if tracker.hasTripped {
            triggerPairRequest(reason: "ble_rssi", distance: nil)
        }
    }

    private func relayDistanceIfNeeded(distanceM: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastDistanceRelayAt) > 0.2 else { return }
        lastDistanceRelayAt = now
        guard let client = pairClient else {
            // No WS yet — first BLE samples can fire before Bonjour
            // discovery + WS connect complete. Quiet warning so we can
            // distinguish "no client" from "send failed."
            return
        }
        do {
            try client.submitNiDistance(distanceM: distanceM)
            LLog.debug("pair", "relayed distance", fields: ["distance_m": distanceM])
        } catch {
            LLog.warn("pair", "relay submit failed", fields: ["error": String(describing: error)])
        }
    }

    // MARK: - Ultrasonic Doppler reader

    private func startUltrasonicReader() {
        guard ultrasonicReader == nil else { return }
        let reader = UltrasonicReader()
        reader.onSample = { [weak self] velocity, peakHz, confidence in
            Task { @MainActor in self?.handleUltrasonicSample(velocity: velocity, peakHz: peakHz, confidence: confidence) }
        }
        ultrasonicReader = reader
        Task { @MainActor in
            do {
                try await reader.start()
            } catch {
                LLog.warn("pair", "ultrasonic reader unavailable", fields: ["error": String(describing: error)])
            }
        }
    }

    private func handleUltrasonicSample(velocity: Float?, peakHz: Float?, confidence: Float?) {
        guard isRunning else { return }
        ultrasonicPeakHz = peakHz
        ultrasonicConfidence = confidence
        if let velocity {
            // Read the smoothed value back out of the reader so the UI
            // sees an EMA-stable velocity rather than per-frame jitter.
            dopplerVelocityMS = ultrasonicReader?.smoothedVelocityMS ?? velocity
        }
    }

    // MARK: - Pair-request trigger

    private func triggerPairRequest(reason: String, distance: Float?) {
        guard !debugMode, !didSendPairRequest else { return }
        guard state == .handshaking else { return }
        didSendPairRequest = true
        state = .awaitingConfirm
        LLog.info(
            "pair",
            "proximity threshold reached",
            fields: [
                "reason": reason,
                "distance_m": distance.map { String(format: "%.2f", $0) } ?? "—",
                "rssi": lastRssi.map(String.init) ?? "—"
            ]
        )
        // Some Rust hosts expect a numeric distance; pass the NI reading
        // when we have it, otherwise the BLE-derived estimate so the Mac UI
        // still gets a "~Xm" hint.
        let payload = distance ?? bleEstimatedDistance.map(Float.init) ?? 0
        try? pairClient?.submitPairRequest(distanceM: payload)
    }

    private func handlePairAccepted(codexWsUrl: String, lanIp: String) {
        state = .paired
        LLog.info(
            "pair",
            "pair accepted",
            fields: ["codex_ws_url": codexWsUrl, "lan_ip": lanIp]
        )
        let port = Self.extractPort(fromWebSocketURL: codexWsUrl) ?? 8390
        let nameOut = discoveredMacName ?? lanIp
        let saved = SavedServer(
            id: "mac-pair-\(lanIp)",
            name: nameOut,
            hostname: lanIp,
            port: port,
            codexPorts: [port],
            sshPort: nil,
            source: .bonjour,
            hasCodexServer: true,
            wakeMAC: nil,
            preferredConnectionMode: .directCodex,
            preferredCodexPort: port,
            sshPortForwardingEnabled: nil,
            websocketURL: codexWsUrl,
            rememberedByUser: true
        )
        var list = SavedServerStore.load()
        list.removeAll { $0.id == saved.id || $0.hostname == saved.hostname }
        list.append(saved)
        SavedServerStore.save(list)
        completedServer = saved
        isRunning = false
        teardown()
    }

    private static func extractPort(fromWebSocketURL url: String) -> UInt16? {
        guard let parsed = URL(string: url), let port = parsed.port,
              port > 0, port <= Int(UInt16.max) else {
            return nil
        }
        return UInt16(port)
    }

    // MARK: - Timeout + teardown

    private func startFlowTimeout() {
        flowTimeoutTask?.cancel()
        flowTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flowTimeout * 1_000_000_000))
            guard let self, self.isRunning else { return }
            if self.state == .searching || self.state == .connecting
                || self.state == .handshaking || self.state == .awaitingConfirm {
                LLog.info("pair", "flow timeout reached")
                self.state = .failed
            }
        }
    }

    private func teardown() {
        browseTask?.cancel()
        browseTask = nil
        browser = nil
        flowTimeoutTask?.cancel()
        flowTimeoutTask = nil
        pollTask?.cancel()
        pollTask = nil
        if let client = pairClient {
            pairClient = nil
            Task { await client.stop() }
        }
        if let session = niSession {
            session.invalidate()
            niSession = nil
        }
        niDelegateBox = nil
        pendingMacDiscoveryToken = nil
        bleScanner?.stop()
        bleScanner = nil
        bleTrackers.removeAll()
        bleStrongestPeer = nil
        ultrasonicReader?.stop()
        ultrasonicReader = nil
    }
}

// MARK: - NI token coding helpers

private func encodeDiscoveryToken(_ token: NIDiscoveryToken) throws -> String {
    let data = try NSKeyedArchiver.archivedData(
        withRootObject: token,
        requiringSecureCoding: true
    )
    return data.base64EncodedString()
}

private func decodeDiscoveryToken(_ data: Data) -> NIDiscoveryToken? {
    return try? NSKeyedUnarchiver.unarchivedObject(
        ofClass: NIDiscoveryToken.self,
        from: data
    )
}

// MARK: - NI delegate shim

/// Minimal NSObject delegate box so `NearbyMacPairing` (an `Observable`
/// class) can stay non-NSObject. Delegates the two callbacks we care
/// about: `didUpdate nearbyObjects` → distance updates, and session
/// invalidation → teardown hook.
private final class NIDelegateBox: NSObject, NISessionDelegate, @unchecked Sendable {
    private let onUpdate: (NINearbyObject?) -> Void
    private let onInvalidated: (Error) -> Void

    init(
        onUpdate: @escaping (NINearbyObject?) -> Void,
        invalidated: @escaping (Error) -> Void
    ) {
        self.onUpdate = onUpdate
        self.onInvalidated = invalidated
    }

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        // We paired with exactly one peer (the Mac) so the first object is
        // ours.
        onUpdate(nearbyObjects.first)
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        onInvalidated(error)
    }

    func sessionWasSuspended(_ session: NISession) {}
    func sessionSuspensionEnded(_ session: NISession) {}
}
#endif
