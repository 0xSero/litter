#if !targetEnvironment(macCatalyst)
import NearbyInteraction
import SwiftUI
import simd

/// Debug surface for the iPhone-side UWB ranging used by the Mac pairing
/// flow. Reuses `NearbyMacPairing.shared` in debug mode (which skips the
/// auto pair_request), so we keep a single browse + WS + NISession path
/// instead of duplicating it.
struct UWBDebugView: View {
    @State private var pairing = NearbyMacPairing.shared
    @State private var now: Date = Date()
    @State private var capabilities: CapabilitiesSummary = .probe()

    private let tick = Timer.publish(every: 0.25, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    capabilitiesCard
                    statusCard
                    distanceCard
                    directionCard
                    bleCard
                    actionButton
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Proximity Debug")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { now = $0 }
        .onDisappear { pairing.stopDebug() }
    }

    // MARK: - Sections

    private var capabilitiesCard: some View {
        card(title: "Device") {
            row("Precise distance", value: capabilities.isSupported ? "yes" : "no")
            row("Precise distance", value: capabilities.preciseDistance.label)
            row("Direction", value: capabilities.direction.label)
            row("Camera assistance", value: capabilities.cameraAssistance.label)
            row("Extended distance", value: capabilities.extendedDistance.label)
        }
    }

    private var statusCard: some View {
        card(title: "Session") {
            row("Running", value: pairing.isRunning ? "yes" : "no")
            row("State", value: stateLabel(pairing.state))
            row("Mac", value: pairing.discoveredMacName ?? "—")
            if let last = pairing.lastUpdate {
                let delta = max(0, now.timeIntervalSince(last))
                row("Last sample", value: String(format: "%.2fs ago", delta))
            } else {
                row("Last sample", value: "—")
            }
        }
    }

    private var distanceCard: some View {
        card(title: "Distance") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(pairing.lastDistance.map { String(format: "%.2f", $0) } ?? "—")
                    .litterFont(size: 36, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                Text("m")
                    .litterFont(.subheadline)
                    .foregroundColor(LitterTheme.textMuted)
            }
            DistanceBar(meters: pairing.lastDistance)
        }
    }

    private var directionCard: some View {
        card(title: "Direction") {
            HStack(spacing: 16) {
                CompassView(direction: pairing.lastDirection,
                            horizontalAngle: pairing.lastHorizontalAngle)
                    .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 6) {
                    if let dir = pairing.lastDirection {
                        row("x", value: String(format: "%+.3f", dir.x))
                        row("y", value: String(format: "%+.3f", dir.y))
                        row("z", value: String(format: "%+.3f", dir.z))
                        let az = atan2(dir.x, -dir.z) * 180 / .pi
                        let el = asin(max(-1, min(1, dir.y))) * 180 / .pi
                        row("azimuth", value: String(format: "%+.1f°", az))
                        row("elevation", value: String(format: "%+.1f°", el))
                    } else {
                        row("vector", value: "—")
                    }
                    if let h = pairing.lastHorizontalAngle {
                        row("horizontal∠", value: String(format: "%+.1f°", h * 180 / .pi))
                    }
                }
            }
        }
    }

    private var bleCard: some View {
        card(title: "BLE Proximity") {
            row("Last RSSI", value: pairing.lastRssi.map { "\($0) dBm" } ?? "—")
            row("Smoothed", value: pairing.smoothedRssi.map { String(format: "%.1f dBm", $0) } ?? "—")
            row("Bucket", value: pairing.bleProximity.label)
            row("Est. distance", value: pairing.bleEstimatedDistance.map { String(format: "%.1f m", $0) } ?? "—")
        }
    }

    private var actionButton: some View {
        Button {
            if pairing.isRunning {
                pairing.stopDebug()
            } else {
                pairing.startForDebug()
            }
        } label: {
            Text(pairing.isRunning ? "Stop" : "Start")
                .litterFont(.body, weight: .semibold)
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(LitterTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func stateLabel(_ s: NearbyMacPairingState) -> String {
        switch s {
        case .searching: return "searching"
        case .connecting: return "connecting"
        case .handshaking: return "ranging"
        case .awaitingConfirm: return "awaiting confirm"
        case .paired: return "paired"
        case .rejected: return "rejected"
        case .failed: return "failed"
        }
    }

    @ViewBuilder
    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .litterFont(.caption, weight: .semibold)
                .foregroundColor(LitterTheme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(LitterTheme.surface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func row(_ key: String, value: String) -> some View {
        HStack {
            Text(key)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textMuted)
            Spacer()
            Text(value)
                .litterFont(.footnote, weight: .medium)
                .foregroundColor(LitterTheme.textPrimary)
        }
    }
}

/// Visualizes proximity. Empty at >=4m, full at <=0.3m.
private struct DistanceBar: View {
    let meters: Float?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LitterTheme.surface)
                    .frame(height: 6)
                Capsule().fill(LitterTheme.accent)
                    .frame(width: geo.size.width * CGFloat(fill), height: 6)
            }
        }
        .frame(height: 6)
    }

    private var fill: Float {
        guard let m = meters else { return 0 }
        let clamped = min(max(m, 0.0), 4.0)
        return max(0, min(1, (4.0 - clamped) / 3.7))
    }
}

/// Compass-style arrow that points in the azimuth of the peer (top of the
/// dial = directly in front of the phone). Falls back to horizontal angle
/// when full direction isn't available.
private struct CompassView: View {
    let direction: simd_float3?
    let horizontalAngle: Float?

    var body: some View {
        ZStack {
            Circle()
                .stroke(LitterTheme.border, lineWidth: 1)
            Circle()
                .fill(LitterTheme.surface.opacity(0.4))
            // Crosshair
            Path { p in
                p.move(to: CGPoint(x: 60, y: 0)); p.addLine(to: CGPoint(x: 60, y: 120))
                p.move(to: CGPoint(x: 0, y: 60)); p.addLine(to: CGPoint(x: 120, y: 60))
            }
            .stroke(LitterTheme.border.opacity(0.4), lineWidth: 0.5)
            arrow
            Text("front")
                .litterFont(size: 9)
                .foregroundColor(LitterTheme.textMuted)
                .offset(y: -52)
        }
    }

    @ViewBuilder
    private var arrow: some View {
        if let azimuth = azimuthRadians {
            Image(systemName: "location.north.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundColor(LitterTheme.accent)
                .scaleEffect(elevationScale)
                .rotationEffect(.radians(Double(azimuth)))
        } else {
            Image(systemName: "questionmark")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundColor(LitterTheme.textMuted)
        }
    }

    private var azimuthRadians: Float? {
        if let d = direction {
            return atan2(d.x, -d.z)
        }
        return horizontalAngle
    }

    /// Shrink the arrow when the peer is far above/below to hint elevation.
    private var elevationScale: CGFloat {
        guard let d = direction else { return 1 }
        let mag = abs(d.y)
        return CGFloat(max(0.55, 1.0 - mag * 0.6))
    }
}

/// Snapshot of device UWB capabilities, captured once when the view appears
/// so the SwiftUI body doesn't construct a fresh `NISession` on every redraw.
private struct CapabilitiesSummary {
    enum Tri { case yes, no, unknown
        var label: String {
            switch self {
            case .yes: return "yes"
            case .no: return "no"
            case .unknown: return "—"
            }
        }
    }

    let isSupported: Bool
    let preciseDistance: Tri
    let direction: Tri
    let cameraAssistance: Tri
    let extendedDistance: Tri

    static func probe() -> CapabilitiesSummary {
        let supported = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
        guard supported else {
            return CapabilitiesSummary(
                isSupported: supported,
                preciseDistance: .unknown,
                direction: .unknown,
                cameraAssistance: .unknown,
                extendedDistance: .unknown
            )
        }
        let caps = NISession.deviceCapabilities
        return CapabilitiesSummary(
            isSupported: true,
            preciseDistance: caps.supportsPreciseDistanceMeasurement ? .yes : .no,
            direction: caps.supportsDirectionMeasurement ? .yes : .no,
            cameraAssistance: caps.supportsCameraAssistance ? .yes : .no,
            extendedDistance: caps.supportsExtendedDistanceMeasurement ? .yes : .no
        )
    }
}

#if DEBUG
#Preview("UWB Debug") {
    NavigationStack { UWBDebugView() }
}
#endif
#endif
