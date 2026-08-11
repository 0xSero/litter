#if targetEnvironment(macCatalyst)
import Foundation
import NearbyInteraction
import UIKit

/// Mac-side pair host. Runs only on the unsandboxed (direct-dist) Catalyst
/// lane alongside the Feature A local codex. Publishes a Bonjour service
/// (`_litter-pair._tcp.`) whose port is owned by the Rust pair host, then
/// drives NISession + confirm dialog when iPhones connect.
///
/// Wiring: Rust owns the WS listener, pair protocol state machine, and the
/// event stream. Swift here owns the native surface:
///   * NetService publish (Bonjour)
///   * NISession with the iPhone's discovery token
///   * UIAlertController confirm dialog
///   * LAN IP resolution via getifaddrs (en0/en1 IPv4)
@MainActor
@Observable
final class MacPairingHost: NSObject {
    static let shared = MacPairingHost()

    private static let pairServiceType = "_litter-pair._tcp."
    /// TXT record domain (unused by the iPhone flow but standard-conformant).
    private static let bonjourDomain = ""
    /// Persisted mac-id key; random UUID on first launch, stable across
    /// restarts so reconnecting iPhones can recognize the same Mac.
    private static let macIdUserDefaultsKey = "litter.mac_pair_id"
    /// Unique 4-hex-digit suffix appended to the Bonjour service name on
    /// every launch. mDNSResponder caches the previous registration for
    /// ~2 minutes after a process exits; without a fresh suffix, the next
    /// launch hits NSNetServicesCollisionError (-72008) and the relaunch
    /// silently fails to publish on Wi-Fi.
    private static let launchNonce: String = String(format: "%04X", UInt16.random(in: 0...UInt16.max))

    /// Observable peer-state for the unified ProximityPairView. Updated as
    /// pair events stream in from Rust. iPhone owns the actual proximity
    /// readings (UWB or BLE) and relays them via `submitNiDistance`; the Mac
    /// side just mirrors what the iPhone reports.
    var isHostActive: Bool = false
    var peerName: String?
    var peerDistance: Float?
    var lastUpdate: Date?
    var awaitingConfirm: Bool = false
    var isPaired: Bool = false

    private let appClient = AppClient()
    private var hostHandle: PairHostHandle?
    private var pollTask: Task<Void, Never>?
    private var bonjourService: NetService?
    private var bonjourDelegate: BonjourServicePublishDelegate?
    private var niSession: NISession?
    private var niDelegateBox: NIDelegateBox?
    private var bleAdvertiser: PairBLEAdvertiser?
    private var ultrasonicEmitter: UltrasonicEmitter?
    private var isBroadcasting = false
    private var pendingAlert: UIAlertController?

    override private init() {
        super.init()
    }

    /// Stand up the pair host (WS listener + Bonjour publish + BLE beacon)
    /// and prime an NI session for any iPhones that pair. Safe to call
    /// repeatedly; subsequent calls are no-ops.
    ///
    /// Runs in **any** Catalyst build, including sandboxed Debug
    /// (`catalyst-fast-run`). The follow-up `pair_accept` will only point
    /// the iPhone at a working local Codex when `LitterPlatform.isDirectDistMac`
    /// is also true (sandboxed Catalyst can't fork a codex child); in
    /// sandboxed builds the pair flow completes the handshake but the
    /// iPhone's subsequent connect to port 8390 will get nothing — that's
    /// expected and useful for testing the BLE proximity path without the
    /// slow DeveloperID build cycle.
    func startIfNeeded() {
        guard LitterPlatform.isCatalyst else { return }
        guard !isBroadcasting else { return }
        isBroadcasting = true
        let macId = Self.resolveMacId()
        let deviceName = LitterPlatform.localRuntimeDisplayName()
        let codexPort = LocalCodexBootstrap.port
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.appClient.startPairHost(
                    deviceName: deviceName,
                    macId: macId,
                    codexPort: codexPort
                )
                self.hostHandle = result.handle
                self.isHostActive = true
                LLog.info(
                    "pair",
                    "pair host started",
                    fields: [
                        "port": Int(result.info.port),
                        "mac_id": macId
                    ]
                )
                // Prime NI discovery token now so the first hello has a
                // valid token to echo back. No-ops on Macs without UWB
                // (which is currently every Mac); BLE advertising below
                // covers the proximity signal in that case.
                self.prepareNISession()
                self.startBLEAdvertiser(macId: macId)
                self.startUltrasonicEmitter()
                self.publishBonjour(info: result.info)
                self.startEventPoll()
            } catch {
                LLog.error("pair", "failed to start pair host", error: error)
                self.isBroadcasting = false
            }
        }
    }

    /// User toggled "Stop broadcasting" in Settings. Stops Bonjour, the BLE
    /// advertiser, and the pair host; NI sessions are torn down with it.
    func stop() {
        isBroadcasting = false
        isHostActive = false
        peerName = nil
        peerDistance = nil
        awaitingConfirm = false
        isPaired = false
        bonjourService?.stop()
        bonjourService?.delegate = nil
        bonjourService = nil
        bonjourDelegate = nil
        pollTask?.cancel()
        pollTask = nil
        if let session = niSession {
            session.invalidate()
            niSession = nil
        }
        niDelegateBox = nil
        bleAdvertiser?.stop()
        bleAdvertiser = nil
        ultrasonicEmitter?.stop()
        ultrasonicEmitter = nil
        if let handle = hostHandle {
            hostHandle = nil
            Task { await handle.stop() }
        }
    }

    // MARK: - BLE proximity beacon

    private func startBLEAdvertiser(macId: String) {
        let advertiser = PairBLEAdvertiser()
        // Bluetooth advertisements have ~31 bytes total; leave room for the
        // service-UUID overhead by truncating mac_id to its first 8 chars.
        let prefix = String(macId.prefix(8))
        advertiser.start(localName: "litter:\(prefix)")
        bleAdvertiser = advertiser
    }

    // MARK: - Ultrasonic Doppler beacon

    private func startUltrasonicEmitter() {
        let emitter = UltrasonicEmitter()
        emitter.start()
        ultrasonicEmitter = emitter
    }

    // MARK: - Bonjour

    private func publishBonjour(info: PairServiceInfo) {
        let uniqueName = "\(info.serviceName) #\(Self.launchNonce)"
        let service = NetService(
            domain: Self.bonjourDomain,
            type: Self.pairServiceType,
            name: uniqueName,
            port: Int32(info.port)
        )
        // Convert `key=value` strings into a TXT dictionary.
        var txt: [String: Data] = [:]
        for entry in info.txtEntries {
            guard let sep = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<sep])
            let value = String(entry[entry.index(after: sep)...])
            txt[key] = value.data(using: .utf8) ?? Data()
        }
        if !txt.isEmpty {
            service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        }
        let delegate = BonjourServicePublishDelegate()
        service.delegate = delegate
        service.schedule(in: .main, forMode: .common)
        service.publish()
        bonjourService = service
        bonjourDelegate = delegate
        LLog.info(
            "pair",
            "bonjour service published",
            fields: ["type": Self.pairServiceType, "name": info.serviceName, "port": Int(info.port)]
        )
    }

    // MARK: - NISession

    private func prepareNISession() {
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            LLog.info("pair", "NISession unsupported on this Mac; iPhone will fall back")
            return
        }
        let session = NISession()
        let delegate = NIDelegateBox()
        session.delegate = delegate
        niSession = session
        niDelegateBox = delegate
        guard let token = session.discoveryToken,
              let encoded = try? encodeDiscoveryToken(token)
        else {
            LLog.warn("pair", "NISession produced no discovery token on Mac")
            return
        }
        // Stash the token in Rust for the next hello handshake.
        if let host = hostHandle {
            Task { await host.setNiDiscoveryToken(tokenB64: encoded) }
        }
    }

    // MARK: - Event loop

    private func startEventPoll() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self, let host = self.hostHandle {
                if let event = await host.pollEvent() {
                    self.handle(event: event)
                } else {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            }
        }
    }

    private func handle(event: PairEvent) {
        switch event {
        case let .hostPeerConnected(deviceName, niDiscoveryTokenB64):
            peerName = deviceName
            isPaired = false
            awaitingConfirm = false
            handleIncomingHello(deviceName: deviceName, niTokenB64: niDiscoveryTokenB64)
        case let .hostPairRequest(distanceM):
            awaitingConfirm = true
            if let distanceM { peerDistance = distanceM; lastUpdate = Date() }
            showConfirmDialog(distanceM: distanceM)
        case let .distanceUpdate(distanceM):
            // iPhone-side proximity stream (UWB or BLE-derived). Drives the
            // Mac's ProximityPairView animation in real time.
            peerDistance = distanceM
            lastUpdate = Date()
            LLog.debug("pair", "received distance", fields: ["distance_m": distanceM])
        case let .disconnected(reason):
            LLog.info("pair", "mac disconnected", fields: ["reason": reason])
            peerName = nil
            peerDistance = nil
            awaitingConfirm = false
            // Refresh NI session for the next connection so discovery
            // tokens roll forward.
            if let session = niSession {
                session.invalidate()
            }
            niSession = nil
            niDelegateBox = nil
            prepareNISession()
        case .clientPairAccepted, .clientPeerAccepted, .peerRejected:
            // Client-side events; host ignores.
            break
        }
    }

    private func handleIncomingHello(deviceName: String, niTokenB64: String) {
        LLog.info(
            "pair",
            "pair hello received",
            fields: ["device_name": deviceName]
        )
        guard let session = niSession,
              let data = Data(base64Encoded: niTokenB64),
              !data.isEmpty,
              let token = decodeDiscoveryToken(data)
        else {
            LLog.warn("pair", "incoming iPhone NI token unusable; proceeding without ranging")
            return
        }
        let config = NINearbyPeerConfiguration(peerToken: token)
        session.run(config)
    }

    private func showConfirmDialog(distanceM: Float?) {
        // Catalyst surfaces UIAlertController as a sheet-style native
        // dialog. Present from the active foreground window's root view
        // controller.
        guard let host = hostHandle else { return }
        let deviceLabel: String = {
            // Best-effort: the iPhone's device_name is captured in the
            // earlier HostPeerConnected event. We didn't thread it through;
            // a simple placeholder is fine since the Mac user knows which
            // of their iPhones is close.
            return "iPhone"
        }()
        let distanceSuffix = distanceM.map { String(format: " (~%.1fm)", $0) } ?? ""
        let alert = UIAlertController(
            title: "Pair with \(deviceLabel)?",
            message: "\(deviceLabel)\(distanceSuffix) wants to pair with this Mac as its Litter home base.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Accept", style: .default) { [weak self] _ in
            guard let self else { return }
            let lanIp = Self.resolveLANIPv4() ?? "127.0.0.1"
            Task {
                do {
                    try await host.acceptPairRequest(
                        accepted: true,
                        lanIp: lanIp,
                        codexPort: LocalCodexBootstrap.port
                    )
                    self.isPaired = true
                    self.awaitingConfirm = false
                    LLog.info("pair", "accepted pair", fields: ["lan_ip": lanIp])
                } catch {
                    LLog.error("pair", "accept failed", error: error)
                }
            }
        })
        alert.addAction(UIAlertAction(title: "Decline", style: .cancel) { _ in
            Task {
                do {
                    try await host.acceptPairRequest(
                        accepted: false,
                        lanIp: "",
                        codexPort: 0
                    )
                } catch {
                    LLog.error("pair", "decline failed", error: error)
                }
            }
        })
        pendingAlert = alert
        if let root = Self.topViewController() {
            root.present(alert, animated: true)
        } else {
            LLog.warn("pair", "no top view controller to present confirm dialog")
        }
    }

    // MARK: - Helpers

    private static func resolveMacId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: macIdUserDefaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: macIdUserDefaultsKey)
        return fresh
    }

    /// Resolve the first IPv4 address on `en0`/`en1` (typical Wi-Fi /
    /// Ethernet on macOS). Falls back to any non-loopback IPv4 address.
    static func resolveLANIPv4() -> String? {
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else {
            return nil
        }
        defer { freeifaddrs(ifaddrsPtr) }
        var preferred: String?
        var fallback: String?
        var ptr = first
        while true {
            let flags = Int32(ptr.pointee.ifa_flags)
            let name = String(cString: ptr.pointee.ifa_name)
            if (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                let sa = ptr.pointee.ifa_addr
                if let sa, sa.pointee.sa_family == sa_family_t(AF_INET) {
                    var addr = sockaddr_in()
                    memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
                    var raw = addr.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &raw, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let ip = String(cString: buf)
                        if name == "en0" || name == "en1" {
                            preferred = ip
                            break
                        }
                        if fallback == nil {
                            fallback = ip
                        }
                    }
                }
            }
            if let next = ptr.pointee.ifa_next {
                ptr = next
            } else {
                break
            }
        }
        return preferred ?? fallback
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return nil }
        guard let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
            return nil
        }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - NetService publish delegate

private final class BonjourServicePublishDelegate: NSObject, NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        LLog.info(
            "pair",
            "bonjour published",
            fields: ["name": sender.name, "type": sender.type]
        )
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        LLog.warn(
            "pair",
            "bonjour publish failed",
            fields: [
                "name": sender.name,
                "error": errorDict.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            ]
        )
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

private final class NIDelegateBox: NSObject, NISessionDelegate, @unchecked Sendable {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        // Mac side doesn't act on distance — iPhone is the source of
        // truth for "close enough to pair". Distance logs are cheap and
        // useful for debugging onboarding drift.
        if let distance = nearbyObjects.first?.distance {
            LLog.debug("pair", "mac NI distance", fields: ["distance_m": distance])
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        LLog.warn(
            "pair",
            "mac NISession invalidated",
            fields: ["error": String(describing: error)]
        )
    }

    func sessionWasSuspended(_ session: NISession) {}
    func sessionSuspensionEnded(_ session: NISession) {}
}
#endif
