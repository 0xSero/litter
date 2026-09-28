import SwiftUI
#if canImport(WatchKit)
import WatchKit
#endif

extension WatchSize {
    /// Live size from the current device. Falls back to `.regular` off-device
    /// (host tests, previews without an explicit override).
    static var current: WatchSize {
        #if canImport(WatchKit) && os(watchOS)
        let width = WKInterfaceDevice.current().screenBounds.width
        return from(width: width)
        #else
        return .regular
        #endif
    }
}

private struct WatchSizeKey: EnvironmentKey {
    static let defaultValue: WatchSize = .regular
}

extension EnvironmentValues {
    /// Coarse watch-size bucket — read in views to scale fonts/padding.
    var watchSize: WatchSize {
        get { self[WatchSizeKey.self] }
        set { self[WatchSizeKey.self] = newValue }
    }
}

/// Design tokens for the Litter Apple Watch experience.
///
/// Matches the Claude Design handoff: pure #000 OLED, ginger (#F59E0B) as the
/// only accent, green for success. Berkeley mono everywhere, never below 10pt.
enum WatchTheme {
    // MARK: - Palette
    static let bg            = Color.black
    static let surface       = Color(hex: 0x0E0E0E)
    static let surfaceDeep   = Color(hex: 0x0A0A0A)
    static let surfaceHi     = Color(hex: 0x1A1A1A)
    static let border        = Color(hex: 0x222222)
    static let borderHi      = Color(hex: 0x333333)

    static let ginger        = Color(hex: 0xF59E0B)
    static let gingerLight   = Color(hex: 0xFCD472)
    static let amber         = Color(hex: 0xD98A53)
    static let amberDeep     = Color(hex: 0xB06535)
    static let gingerTint    = Color(hex: 0xF59E0B).opacity(0.12)
    static let gingerStroke  = Color(hex: 0xF59E0B).opacity(0.35)

    static let text          = Color(hex: 0xFCFCFC)
    static let dim           = Color(hex: 0x8F8F8F)
    static let dimMore       = Color(hex: 0x555555)
    static let muted         = Color(hex: 0x6D6050)

    static let success       = Color(hex: 0x00FF9C)
    static let successSoft   = Color(hex: 0x85DF7B)
    static let danger        = Color(hex: 0xFF5555)
    static let userBubble    = Color(hex: 0x0169CC)
    static let onAccent      = Color(hex: 0x1F2937)

    // MARK: - Type
    private static let mono = "BerkeleyMono-Regular"
    private static let monoBold = "BerkeleyMono-Bold"

    /// Berkeley Mono is embedded in the parent iOS app. On watchOS falls back to
    /// the system monospaced design when that resource is unavailable.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight == .bold || weight == .heavy ? monoBold : mono
        return Font.custom(name, size: size).weight(weight)
    }

    /// Watch-size-aware mono font. Multiplies `size` by the per-bucket scale
    /// (compact 0.9, regular 1.0, expanded 1.1) so small-screen layouts stay
    /// dense and Ultra-class screens get a touch more breathing room.
    static func scaled(_ size: CGFloat, for watchSize: WatchSize, weight: Font.Weight = .regular) -> Font {
        mono(size * watchSize.fontScale, weight: weight)
    }
}

// MARK: - Hex helper

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8)  & 0xFF) / 255
        let b = Double(hex         & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
