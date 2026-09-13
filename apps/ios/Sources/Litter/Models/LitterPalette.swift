import SwiftUI

/// Parses CSS hex with alpha last (`#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`)
/// into normalized RGBA components, or nil for anything else.
///
/// Lives in this file because both the main app target and the
/// `LitterLiveActivity` extension compile `LitterPalette.swift`.
func LitterHexRGBA(_ hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    var digits = Array(value.lowercased())
    if digits.count == 3 || digits.count == 4 {
        digits = digits.flatMap { [$0, $0] }
    }
    guard digits.count == 6 || digits.count == 8,
          let int = UInt64(String(digits), radix: 16)
    else { return nil }
    let alpha = digits.count == 8 ? Double(int & 0xFF) / 255 : 1
    let rgb = digits.count == 8 ? int >> 8 : int
    return (
        Double((rgb >> 16) & 0xFF) / 255,
        Double((rgb >> 8) & 0xFF) / 255,
        Double(rgb & 0xFF) / 255,
        alpha
    )
}

/// Shared color palette used by both the main app (LitterTheme) and the
/// Live Activity widget extension. Reads from the shared App Group
/// UserDefaults (written by ThemeManager) with hardcoded fallbacks.
enum LitterPalette {
    // MARK: - Adaptive pairs (light, dark)

    struct Pair {
        let light: String
        let dark: String
    }

    static let appGroupSuite = "group.com.sigkitten.litter"
    private static let shared = UserDefaults(suiteName: appGroupSuite)

    private static func pair(_ key: String, lightFallback: String, darkFallback: String) -> Pair {
        Pair(
            light: shared?.string(forKey: "theme.light.\(key)") ?? lightFallback,
            dark: shared?.string(forKey: "theme.dark.\(key)") ?? darkFallback
        )
    }

    static var accent: Pair        { pair("accent", lightFallback: "#4A4A4A", darkFallback: "#B0B0B0") }
    static var accentStrong: Pair   { pair("accentStrong", lightFallback: "#00995D", darkFallback: "#00FF9C") }
    static var textPrimary: Pair    { pair("textPrimary", lightFallback: "#1A1A1A", darkFallback: "#FFFFFF") }
    static var textSecondary: Pair  { pair("textSecondary", lightFallback: "#6B6B6B", darkFallback: "#888888") }
    static var textMuted: Pair      { pair("textMuted", lightFallback: "#9E9E9E", darkFallback: "#555555") }
    static var textBody: Pair       { pair("textBody", lightFallback: "#2D2D2D", darkFallback: "#E0E0E0") }
    static var textSystem: Pair     { pair("textSystem", lightFallback: "#3A4A3F", darkFallback: "#C6D0CA") }
    static var surface: Pair        { pair("surface", lightFallback: "#F2F2F7", darkFallback: "#1A1A1A") }
    static var surfaceLight: Pair   { pair("surfaceLight", lightFallback: "#E5E5EA", darkFallback: "#2A2A2A") }
    static var border: Pair         { pair("border", lightFallback: "#D1D1D6", darkFallback: "#333333") }
    static var separator: Pair      { pair("separator", lightFallback: "#E0E0E0", darkFallback: "#1E1E1E") }
    static var danger: Pair         { pair("danger", lightFallback: "#D32F2F", darkFallback: "#FF5555") }
    static var success: Pair        { pair("success", lightFallback: "#2E7D32", darkFallback: "#6EA676") }
    static var warning: Pair        { pair("warning", lightFallback: "#E65100", darkFallback: "#E2A644") }
    static var textOnAccent: Pair   { pair("textOnAccent", lightFallback: "#FFFFFF", darkFallback: "#0D0D0D") }
    static var codeBackground: Pair { pair("codeBackground", lightFallback: "#F0F0F5", darkFallback: "#111111") }

    // MARK: - Font

    /// Font design matching the user's font preference.
    static var fontDesign: Font.Design {
        switch shared?.string(forKey: "fontFamily") ?? "system" {
        case "mono", "system-mono":
            return .monospaced
        case "serif":
            return .serif
        default:
            return .default
        }
    }
}

// MARK: - SwiftUI helpers for widget / preview use

extension LitterPalette.Pair {
    /// Resolve to a SwiftUI `Color` using the SwiftUI color scheme
    /// (works in widgets and previews, unlike UITraitCollection).
    func color(for scheme: ColorScheme) -> Color {
        Self.colorFromHex(scheme == .dark ? dark : light)
    }

    static func colorFromHex(_ hex: String) -> Color {
        if let rgba = LitterHexRGBA(hex) {
            return Color(red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
        }
        return Color(red: 0, green: 0, blue: 0)
    }
}
