import SwiftUI

// MARK: - Theme JSON model (VS Code format)

struct ThemeDefinition: Codable {
    let name: String
    let type: ThemeType
    let colors: [String: String]

    enum ThemeType: String, Codable {
        case light, dark
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case colors
    }

    init(name: String, type: ThemeType, colors: [String: String]) {
        self.name = name
        self.type = type
        self.colors = colors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(ThemeType.self, forKey: .type)

        // VS Code themes occasionally include null entries or non-string
        // values (arrays, objects) under `colors`. Decode tolerantly and
        // drop anything that isn't a string so the rest of the app can
        // assume `[String: String]`.
        let rawColors = try container.decode([String: ThemeColorValue].self, forKey: .colors)
        colors = rawColors.compactMapValues { value in
            value.string.map(Self.sanitizeHex)
        }
    }

    // VS Code allows #RRGGBBAA and #RGBA. Downstream color helpers assume
    // 6-digit RGB and theme tokens must stay opaque (Android strips alpha
    // the same way), so drop the trailing pair at the decode boundary and
    // expand 4-digit shorthand to solid #RRGGBB.
    private static func sanitizeHex(_ raw: String) -> String {
        guard raw.hasPrefix("#") else { return raw }
        let hex = String(raw.dropFirst())
        if hex.count == 8 { return "#" + hex.prefix(6) }
        if hex.count == 4 {
            let digits = Array(hex.lowercased()).prefix(3)
            return "#" + digits.map { "\($0)\($0)" }.joined()
        }
        return raw
    }

    // tokenColors are ignored — syntax highlighting is handled by Hairball
}

private struct ThemeColorValue: Decodable {
    let string: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            string = nil
        } else {
            // Only string values are usable as theme colors; arrays,
            // objects, numbers, etc. fall through as nil and get dropped.
            string = try? container.decode(String.self)
        }
    }
}

// MARK: - Lightweight index entry for picker UI

struct ThemeIndexEntry: Codable, Identifiable {
    let slug: String
    let name: String
    let type: ThemeDefinition.ThemeType
    let accentHex: String
    let backgroundHex: String
    let foregroundHex: String

    var id: String { slug }
}

// MARK: - Resolved theme (app-ready hex values)

struct ResolvedTheme {
    let slug: String
    let name: String
    let type: ThemeDefinition.ThemeType

    let background: String
    let surface: String
    let surfaceLight: String
    let textPrimary: String
    let textSecondary: String
    let textMuted: String
    let textBody: String
    let textSystem: String
    let accent: String
    let accentStrong: String
    let border: String
    let separator: String
    let danger: String
    let success: String
    let warning: String
    let textOnAccent: String
    let codeBackground: String

    init(slug: String, definition d: ThemeDefinition) {
        self.slug = slug
        self.name = d.name
        self.type = d.type
        let c = d.colors

        let bg = c["editor.background"] ?? (d.type == .dark ? "#111111" : "#FFFFFF")
        let fg = c["editor.foreground"] ?? (d.type == .dark ? "#FFFFFF" : "#1A1A1A")

        self.background = bg
        self.textPrimary = fg
        self.surface = c["sideBar.background"] ?? Self.adjustBrightness(bg, by: d.type == .dark ? 0.03 : -0.02)
        self.surfaceLight = c["activityBar.background"] ?? Self.adjustBrightness(self.surface, by: d.type == .dark ? 0.04 : -0.03)
        self.textSecondary = c["sideBar.foreground"] ?? Self.dimColor(fg, factor: 0.55)
        self.textMuted = c["editorLineNumber.foreground"] ?? Self.dimColor(fg, factor: 0.35)
        self.textBody = Self.dimColor(fg, factor: 0.88)
        self.textSystem = Self.dimColor(fg, factor: 0.7)
        self.accent = c["textLink.foreground"] ?? c["button.background"] ?? (d.type == .dark ? "#B0B0B0" : "#4A4A4A")
        self.accentStrong = c["button.background"] ?? c["textLink.foreground"] ?? self.accent
        self.border = c["editorGroup.border"] ?? c["sideBar.border"] ?? Self.adjustBrightness(self.surface, by: d.type == .dark ? 0.05 : -0.05)
        self.separator = c["panel.border"] ?? Self.adjustBrightness(bg, by: d.type == .dark ? 0.04 : -0.04)
        self.danger = d.type == .dark ? "#FF5555" : "#D32F2F"
        self.success = d.type == .dark ? "#6EA676" : "#2E7D32"
        self.warning = d.type == .dark ? "#E2A644" : "#E65100"
        self.codeBackground = bg

        // Compute textOnAccent based on accent brightness
        let accentBright = Self.brightness(of: self.accentStrong)
        self.textOnAccent = accentBright > 0.5 ? "#0D0D0D" : "#FFFFFF"

    }

    // MARK: - Color utilities

    static func brightness(of hex: String) -> Double {
        let (r, g, b) = hexToRGB(hex)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    static func adjustBrightness(_ hex: String, by amount: Double) -> String {
        let (r, g, b) = hexToRGB(hex)
        let nr = min(1, max(0, r + amount))
        let ng = min(1, max(0, g + amount))
        let nb = min(1, max(0, b + amount))
        return rgbToHex(nr, ng, nb)
    }

    static func dimColor(_ hex: String, factor: Double) -> String {
        let (r, g, b) = hexToRGB(hex)
        let brightness = 0.299 * r + 0.587 * g + 0.114 * b
        if brightness > 0.5 {
            // Light foreground on dark bg — dim toward black
            return rgbToHex(r * factor, g * factor, b * factor)
        } else {
            // Dark foreground on light bg — dim toward white
            let inv = 1.0 - factor
            return rgbToHex(r + (1 - r) * inv, g + (1 - g) * inv, b + (1 - b) * inv)
        }
    }

    static func hexToRGB(_ hex: String) -> (Double, Double, Double) {
        // Theme hex is CSS with alpha last; the dimming math uses the RGB
        // channels only.
        guard let rgba = litterHexRGBA(hex) else { return (0, 0, 0) }
        return (rgba.red, rgba.green, rgba.blue)
    }

    static func rgbToHex(_ r: Double, _ g: Double, _ b: Double) -> String {
        String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Default themes (fallback when no JSON loaded)

extension ResolvedTheme {
    static let defaultLight = ResolvedTheme(
        slug: "codex-light",
        definition: ThemeDefinition(name: "Codex Light", type: .light, colors: [
            "editor.background": "#FFFFFF", "editor.foreground": "#0D0D0D",
            "sideBar.background": "#FCFCFC", "sideBar.foreground": "#212121",
            "activityBar.background": "#FCFCFC",
            "textLink.foreground": "#0169CC", "button.background": "#0169CC",
            "gitDecoration.addedResourceForeground": "#00A240",
            "gitDecoration.deletedResourceForeground": "#E02E2A",
        ])
    )

    static let defaultDark = ResolvedTheme(
        slug: "codex-dark",
        definition: ThemeDefinition(name: "Codex Dark", type: .dark, colors: [
            "editor.background": "#111111", "editor.foreground": "#FCFCFC",
            "sideBar.background": "#131313", "sideBar.foreground": "#8F8F8F",
            "activityBar.background": "#131313",
            "textLink.foreground": "#0169CC", "button.background": "#0169CC",
            "gitDecoration.addedResourceForeground": "#00A240",
            "gitDecoration.deletedResourceForeground": "#E02E2A",
        ])
    )
}
