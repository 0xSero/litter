import Foundation
import Observation
import HairballUI
import SwiftUI

enum StreamingEffectKind: String, CaseIterable, Identifiable {
    case fadeEdge = "Fade Edge"
    case sparkle = "Sparkle"
    case glowCursor = "Glow Cursor"
    case wave = "Wave"
    case scalePop = "Scale Pop"
    case rainbow = "Rainbow"
    case fireTrail = "Fire Trail"
    case explosion = "Explosion"
    case nyanCat = "Nyan Cat"
    case matrixDecode = "Matrix Decode"
    case phosphorCRT = "Phosphor CRT"
    case shockwave = "Shockwave"

    var id: String { rawValue }

    var effect: any StreamingTextEffect {
        let accent = Color(red: 0, green: 1, blue: 0.612)
        switch self {
        case .fadeEdge: return FadeEdgeEffect(edgeWidth: 4)
        case .sparkle: return SparkleEffect(sparkleCount: 8, color: accent)
        case .glowCursor: return GlowCursorEffect(glowColor: accent, glowRadius: 8)
        case .wave: return WaveRevealEffect(amplitude: 4, wavelength: 8)
        case .scalePop: return ScalePopEffect(popWidth: 3)
        case .rainbow: return RainbowEffect(trailLength: 12)
        case .fireTrail: return FireTrailEffect(trailLength: 15)
        case .explosion: return ExplosionEffect()
        case .nyanCat: return NyanCatEffect()
        case .matrixDecode: return MatrixDecodeEffect()
        case .phosphorCRT: return PhosphorCRTEffect()
        case .shockwave: return ShockwaveEffect()
        }
    }
}

@Observable
final class DebugSettings {
    static let shared = DebugSettings()

    @ObservationIgnored private let key = "litter.debugSettings"
    @ObservationIgnored private var overrides: [String: Bool]

    private init() {
        overrides = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
    }

    private func persist() {
        UserDefaults.standard.set(overrides, forKey: key)
    }

    var enabled: Bool {
        get { overrides["enabled"] ?? false }
        set { overrides["enabled"] = newValue; persist() }
    }

    var showTurnMetrics: Bool {
        get { overrides["showTurnMetrics"] ?? false }
        set { overrides["showTurnMetrics"] = newValue; persist() }
    }

    var disableMarkdown: Bool {
        get { overrides["disableMarkdown"] ?? false }
        set { overrides["disableMarkdown"] = newValue; persist() }
    }

    /// Non-observable snapshot for use in hot view paths (e.g. per-row
    /// `LitterMarkdownView.body`) where the debug-disable state is only
    /// needed as a read and should not register an observation edge.
    /// Reading `DebugSettings.shared.enabled` directly in body creates an
    /// edge per row; this static accessor avoids that.
    @ObservationIgnored
    static var isMarkdownDisabled: Bool {
        shared.overrides["enabled"] == true && shared.overrides["disableMarkdown"] == true
    }
}
