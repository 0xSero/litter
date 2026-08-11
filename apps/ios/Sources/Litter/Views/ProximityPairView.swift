import SwiftUI
import simd

#if !targetEnvironment(macCatalyst)
/// Source-of-truth abstraction read by the unified view. iPhone reads from
/// `NearbyMacPairing` (the active client); Mac reads from `MacPairingHost`.
/// Each side projects its native observable into a common `ProximityFrame`.
@MainActor
private struct ProximityFrame {
    var phase: ProximityPhase
    var peerName: String?
    /// Best-available distance in meters (NI > BLE-derived). nil = unknown.
    var distanceM: Float?
    /// Approach speed in m/s. Positive = closing in. Only iPhone has this.
    var velocityMS: Float?
    /// Coarse 0–1 proximity score for the visual + haptics. Derived from
    /// distance with a soft-knee curve so it feels right perceptually.
    var proximityScore: Float
    /// Bucket from BLE RSSI, used for haptic threshold crossings.
    var bucket: PairBLE.Bucket
}
#else
@MainActor
private struct ProximityFrame {
    var phase: ProximityPhase
    var peerName: String?
    var distanceM: Float?
    var velocityMS: Float?
    var proximityScore: Float
    var bucket: PairBLE.Bucket
}
#endif

private enum ProximityPhase: Equatable {
    case idle
    case searching
    case detected
    case awaitingConfirm
    case paired
    case rejected
    case failed

    /// Peer-aware status string. iPhone is searching for a Mac; Mac is
    /// waiting for an iPhone to walk up. The "Tap Accept" text only fires
    /// on the Mac side (that's where the confirm dialog lives).
    func statusText(peerLabel: String, isHost: Bool) -> String {
        switch self {
        case .idle:
            return isHost ? "Broadcasting…" : "Tap Start to begin"
        case .searching:
            return isHost ? "Waiting for an \(peerLabel)…" : "Looking for a \(peerLabel)…"
        case .detected:
            return isHost ? "\(peerLabel) detected — walk closer" : "Walk closer to pair"
        case .awaitingConfirm:
            return isHost ? "Tap Accept to confirm" : "Confirm on the \(peerLabel)"
        case .paired: return "Paired ✓"
        case .rejected: return "Pair declined"
        case .failed: return "Couldn't pair"
        }
    }
}

struct ProximityPairView: View {
    #if !targetEnvironment(macCatalyst)
    @State private var pairing = NearbyMacPairing.shared
    @State private var haptics = ProximityHaptics()
    #else
    @State private var host = MacPairingHost.shared
    #endif

    @State private var animatedScore: Float = 0
    @State private var lastFrame: ProximityFrame?

    var body: some View {
        ZStack {
            backgroundGradient
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                pulseField(score: animatedScore, time: t)
                    .blendMode(.plusLighter)
            }
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()
                centerStack
                Spacer()
                actionRow
            }
            .padding(24)
        }
        .navigationTitle("Pair")
        .navigationBarTitleDisplayMode(.inline)
        #if targetEnvironment(macCatalyst)
        .onAppear {
            // Mac pair host (BLE adv + ultrasonic emitter + Bonjour +
            // WS listener) is opt-in — it only runs while this view is
            // visible. Stops on disappear so a closed window doesn't
            // leave the radio fan spinning.
            MacPairingHost.shared.startIfNeeded()
        }
        .onDisappear {
            MacPairingHost.shared.stop()
        }
        #else
        .onAppear {
            haptics.prepare()
            // `startForDebug` runs the full discovery + BLE + ultrasonic
            // stack but skips the auto pair_request submission, so the
            // view stays in proximity-preview mode forever. Switch to
            // `startPairing(appModel:)` (or wire a manual button) once
            // we're ready to actually pair from this surface.
            if !pairing.isRunning {
                pairing.startForDebug()
            }
        }
        .onChange(of: pairing.lastDistance) { _, _ in tickFrame() }
        .onChange(of: pairing.bleEstimatedDistance) { _, _ in tickFrame() }
        .onChange(of: pairing.dopplerVelocityMS) { _, _ in tickFrame() }
        .onChange(of: pairing.bleProximity) { _, new in haptics.bucketChanged(to: new) }
        .onChange(of: pairing.state) { _, new in
            switch new {
            case .paired: haptics.success()
            case .failed, .rejected: haptics.failure()
            default: break
            }
        }
        .onDisappear {
            haptics.stop()
            pairing.cancel()
        }
        #endif
    }

    // MARK: - Visual sub-views

    private var backgroundGradient: some View {
        let s = CGFloat(animatedScore)
        return LinearGradient(
            colors: [
                Color.black,
                LitterTheme.surface.opacity(0.4 + 0.4 * s)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    /// Three concentric rings + a halo around the peer-icon, all keyed off
    /// the smoothed proximity score. Pulses faster as you get closer; the
    /// halo brightens too.
    private func pulseField(score: Float, time: TimeInterval) -> some View {
        let s = CGFloat(score)
        // Pulse period shrinks from 1.6s (far) to 0.45s (very close).
        let period = 1.6 - 1.15 * Double(score)
        let phase = (time.truncatingRemainder(dividingBy: period)) / period
        return GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let maxRadius = min(geo.size.width, geo.size.height) * 0.55
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let offset = CGFloat(i) / 3.0
                    let p = (CGFloat(phase) + offset).truncatingRemainder(dividingBy: 1.0)
                    let radius = (0.15 + p * 0.85) * maxRadius
                    let opacity = max(0, 1.0 - p) * (0.25 + 0.5 * s)
                    Circle()
                        .stroke(LitterTheme.accent.opacity(Double(opacity)), lineWidth: 2)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)
                }
                // Halo around the peer icon — brightens with proximity.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                LitterTheme.accent.opacity(0.6 * Double(s)),
                                LitterTheme.accent.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: maxRadius * 0.4
                        )
                    )
                    .frame(width: maxRadius * 0.8, height: maxRadius * 0.8)
                    .position(center)
            }
        }
    }

    private var centerStack: some View {
        let frame = currentFrame()
        return VStack(spacing: 18) {
            Image(systemName: peerIconName)
                .font(.system(size: 64, weight: .light))
                .foregroundColor(LitterTheme.accent)
                .shadow(color: LitterTheme.accent.opacity(Double(animatedScore) * 0.8), radius: 24)
                .scaleEffect(1 + CGFloat(animatedScore) * 0.08)
                .animation(.smooth, value: animatedScore)

            if let name = frame.peerName {
                Text(name)
                    .litterFont(.title3, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
            } else {
                Text(frame.phase == .searching ? "Searching…" : "—")
                    .litterFont(.title3, weight: .semibold)
                    .foregroundColor(LitterTheme.textSecondary)
            }

            distanceReadout(frame: frame)

            Text(frame.phase.statusText(peerLabel: peerLabel, isHost: isHost))
                .litterFont(.subheadline)
                .foregroundColor(LitterTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    /// "Mac" on the iPhone, "iPhone" on the Mac — used in status copy.
    private var peerLabel: String {
        #if targetEnvironment(macCatalyst)
        return "iPhone"
        #else
        return "Mac"
        #endif
    }

    /// True when this view is rendered on the host (Mac) side. Determines
    /// whether status copy says "Waiting for X" vs "Looking for X" and
    /// whether the action row is passive vs interactive.
    private var isHost: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    private func distanceReadout(frame: ProximityFrame) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(frame.distanceM.map { String(format: "%.1f", $0) } ?? "—")
                .litterFont(size: 56, weight: .semibold)
                .foregroundColor(LitterTheme.textPrimary)
                .contentTransition(.numericText())
            Text("m")
                .litterFont(.title3)
                .foregroundColor(LitterTheme.textMuted)
            if let v = frame.velocityMS, abs(v) > 0.1 {
                let arrow = v > 0 ? "arrow.down.right" : "arrow.up.left"
                let color = v > 0 ? LitterTheme.accentStrong : LitterTheme.textMuted
                Image(systemName: arrow)
                    .litterFont(.subheadline)
                    .foregroundColor(color)
                Text(String(format: "%.1f m/s", abs(v)))
                    .litterFont(.subheadline)
                    .foregroundColor(color)
            }
        }
    }

    private var actionRow: some View {
        let frame = currentFrame()
        return HStack(spacing: 12) {
            #if !targetEnvironment(macCatalyst)
            Button(role: .cancel) {
                pairing.cancel()
            } label: {
                Text("Cancel")
                    .litterFont(.body, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(LitterTheme.surface)
                    .foregroundColor(LitterTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if frame.phase == .failed || frame.phase == .rejected {
                Button {
                    pairing.retry()
                } label: {
                    Text("Retry")
                        .litterFont(.body, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(LitterTheme.accent)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            #else
            // On the Mac side the host runs continuously; nothing to
            // start/stop from this screen. Show a passive status pill.
            Text(frame.phase == .paired ? "Paired" : (frame.peerName != nil ? "Connected" : "Broadcasting"))
                .litterFont(.body, weight: .semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(LitterTheme.surface.opacity(0.8))
                .foregroundColor(LitterTheme.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            #endif
        }
    }

    // MARK: - Frame derivation

    private var peerIconName: String {
        #if targetEnvironment(macCatalyst)
        return "iphone"
        #else
        return "desktopcomputer"
        #endif
    }

    private func currentFrame() -> ProximityFrame {
        #if !targetEnvironment(macCatalyst)
        let dist: Float? = pairing.lastDistance ?? pairing.bleEstimatedDistance.map(Float.init)
        let velocity: Float? = pairing.dopplerVelocityMS
        let phase: ProximityPhase = {
            switch pairing.state {
            case .searching: return pairing.discoveredMacName == nil ? .searching : .detected
            case .connecting, .handshaking: return .detected
            case .awaitingConfirm: return .awaitingConfirm
            case .paired: return .paired
            case .rejected: return .rejected
            case .failed: return .failed
            }
        }()
        return ProximityFrame(
            phase: phase,
            peerName: pairing.discoveredMacName,
            distanceM: dist,
            velocityMS: velocity,
            proximityScore: scoreFromDistance(dist),
            bucket: pairing.bleProximity
        )
        #else
        let phase: ProximityPhase = {
            if host.isPaired { return .paired }
            if host.awaitingConfirm { return .awaitingConfirm }
            if host.peerName != nil { return .detected }
            if host.isHostActive { return .searching }
            return .idle
        }()
        return ProximityFrame(
            phase: phase,
            peerName: host.peerName,
            distanceM: host.peerDistance,
            velocityMS: nil,
            proximityScore: scoreFromDistance(host.peerDistance),
            bucket: .unknown
        )
        #endif
    }

    /// Soft-knee curve: 0 m → 1.0, 0.5 m → 0.85, 1 m → 0.65, 2 m → 0.35,
    /// 4 m → 0.05, beyond → 0. Makes the visual respond noticeably the
    /// moment you start moving while still topping out cleanly at contact.
    private func scoreFromDistance(_ d: Float?) -> Float {
        guard let d, d.isFinite, d >= 0 else { return 0 }
        return max(0, min(1, Float(exp(-Double(d) * 0.7))))
    }

    /// Recompute frame and animate the score toward it. Called from
    /// observable change handlers, not the timeline (so we don't churn
    /// every 16 ms).
    private func tickFrame() {
        let frame = currentFrame()
        lastFrame = frame
        withAnimation(.smooth(duration: 0.35)) {
            animatedScore = frame.proximityScore
        }
        #if !targetEnvironment(macCatalyst)
        let approaching = (frame.velocityMS ?? 0) > 0.15
        haptics.update(proximity: frame.proximityScore, approaching: approaching)
        #endif
    }
}
