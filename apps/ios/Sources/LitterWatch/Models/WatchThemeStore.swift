import SwiftUI

/// Observable holder for the active palette pushed from the iPhone. Falls back
/// to `WatchTheme` defaults until a payload arrives, so cold launches with no
/// snapshot look identical to the prior hardcoded design.
@MainActor
final class WatchThemeStore: ObservableObject {
    static let shared = WatchThemeStore()

    @Published private(set) var palette: WatchThemePayload?

    func apply(_ payload: WatchThemePayload?) {
        guard payload != palette else { return }
        palette = payload
    }

    // MARK: - Resolved colors

    var accent: Color        { palette.map { Color(themeHex: $0.accent) } ?? WatchTheme.ginger }
    var accentStrong: Color  { palette.map { Color(themeHex: $0.accentStrong) } ?? WatchTheme.ginger }
    var accentSoft: Color    { accent.opacity(0.7) }
    var textPrimary: Color   { palette.map { Color(themeHex: $0.textPrimary) } ?? WatchTheme.text }
    var textSecondary: Color { palette.map { Color(themeHex: $0.textSecondary) } ?? WatchTheme.dim }
    var textMuted: Color     { palette.map { Color(themeHex: $0.textMuted) } ?? WatchTheme.dimMore }
    var surface: Color       { palette.map { Color(themeHex: $0.surface) } ?? WatchTheme.surface }
    var surfaceLight: Color  { palette.map { Color(themeHex: $0.surfaceLight) } ?? WatchTheme.surfaceHi }
    var border: Color        { palette.map { Color(themeHex: $0.border) } ?? WatchTheme.border }
    var borderHi: Color      { border.opacity(0.85) }
    var danger: Color        { palette.map { Color(themeHex: $0.danger) } ?? WatchTheme.danger }
    var success: Color       { palette.map { Color(themeHex: $0.success) } ?? WatchTheme.success }
    var successSoft: Color   { success.opacity(0.7) }
    var warning: Color       { palette.map { Color(themeHex: $0.warning) } ?? WatchTheme.ginger }
    var textOnAccent: Color  { palette.map { Color(themeHex: $0.textOnAccent) } ?? WatchTheme.onAccent }

    var backgroundTop: Color    { palette.map { Color(themeHex: $0.backgroundTop) } ?? WatchTheme.bg }
    var backgroundBottom: Color { palette.map { Color(themeHex: $0.backgroundBottom) } ?? WatchTheme.bg }

    var backgroundGradient: LinearGradient {
        LinearGradient(colors: [backgroundTop, backgroundBottom],
                       startPoint: .top, endPoint: .bottom)
    }

    var isDark: Bool { palette?.isDark ?? true }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

// MARK: - String hex helper (distinct label avoids colliding with Color(hex: UInt32))

extension Color {
    init(themeHex string: String) {
        // Theme hex is CSS with alpha last: #RGB/#RGBA/#RRGGBB/#RRGGBBAA.
        // The watch target doesn't compile the app's litterHexRGBA helper,
        // so keep this parse in step with it.
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        var digits = Array(value.lowercased())
        // A leading sign is not a hex digit; UInt64(_:radix:) would still
        // accept one, so require hex digits before parsing.
        guard digits.allSatisfy(\.isHexDigit) else {
            self.init(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
            return
        }
        if digits.count == 3 || digits.count == 4 {
            digits = digits.flatMap { [$0, $0] }
        }
        guard digits.count == 6 || digits.count == 8,
              let v = UInt64(String(digits), radix: 16)
        else {
            self.init(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
            return
        }
        let opacity = digits.count == 8 ? Double(v & 0xFF) / 255 : 1
        let rgb = digits.count == 8 ? v >> 8 : v
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: opacity
        )
    }
}
