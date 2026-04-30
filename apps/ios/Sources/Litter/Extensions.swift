import SwiftUI
import UIKit

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8) & 0xFF) / 255
        let b = CGFloat(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - Central Theme

enum LitterTheme {
    private static var light: ResolvedTheme { ThemeStore.shared.light }
    private static var dark: ResolvedTheme { ThemeStore.shared.dark }

    static func adaptive(light: String, dark: String) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static var accent: Color        { adaptive(light: light.accent, dark: dark.accent) }
    static var accentStrong: Color   { adaptive(light: light.accentStrong, dark: dark.accentStrong) }
    static var textPrimary: Color    { adaptive(light: light.textPrimary, dark: dark.textPrimary) }
    static var textSecondary: Color  { adaptive(light: light.textSecondary, dark: dark.textSecondary) }
    static var textMuted: Color      { adaptive(light: light.textMuted, dark: dark.textMuted) }
    static var textBody: Color       { adaptive(light: light.textBody, dark: dark.textBody) }
    static var textSystem: Color     { adaptive(light: light.textSystem, dark: dark.textSystem) }
    static var surface: Color        { adaptive(light: light.surface, dark: dark.surface) }
    static var surfaceLight: Color   { adaptive(light: light.surfaceLight, dark: dark.surfaceLight) }
    static var border: Color         { adaptive(light: light.border, dark: dark.border) }
    static var separator: Color      { adaptive(light: light.separator, dark: dark.separator) }
    static var danger: Color         { adaptive(light: light.danger, dark: dark.danger) }
    static var success: Color        { adaptive(light: light.success, dark: dark.success) }
    static var warning: Color        { adaptive(light: light.warning, dark: dark.warning) }
    static var textOnAccent: Color   { adaptive(light: light.textOnAccent, dark: dark.textOnAccent) }
    static var codeBackground: Color { adaptive(light: light.codeBackground, dark: dark.codeBackground) }

    static let overlayScrim: Color = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.5)
            : UIColor.black.withAlphaComponent(0.3)
    })

    static var gradientColors: [Color] {
        let isDark = UITraitCollection.current.userInterfaceStyle == .dark
        let theme = isDark ? dark : light
        return gradientColors(for: theme, isDark: isDark)
    }

    static func gradientColors(for colorScheme: ColorScheme) -> [Color] {
        let isDark = colorScheme == .dark
        let theme = isDark ? dark : light
        return gradientColors(for: theme, isDark: isDark)
    }

    private static func gradientColors(for theme: ResolvedTheme, isDark: Bool) -> [Color] {
        let bg = theme.background
        return [
            Color(hex: bg),
            Color(hex: ResolvedTheme.adjustBrightness(bg, by: isDark ? 0.02 : -0.01)),
            Color(hex: ResolvedTheme.adjustBrightness(bg, by: isDark ? -0.01 : 0.01)),
        ]
    }

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func backgroundGradient(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: gradientColors(for: colorScheme),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var headerScrim: [Color] {
        let isDark = UITraitCollection.current.userInterfaceStyle == .dark
        let bg = isDark ? dark.background : light.background
        let bgColor = Color(hex: bg)
        return [bgColor.opacity(0.7), bgColor.opacity(0.3), .clear]
    }
}

enum FontFamilyOption: String, CaseIterable, Identifiable {
    case mono = "mono"
    case system = "system"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mono: return "Monospaced"
        case .system: return "System (SF Pro)"
        }
    }

    var isMono: Bool { self == .mono }
}

enum LitterFont {
    private static let berkeleyRegular = "BerkeleyMono-Regular"
    private static let berkeleyBold = "BerkeleyMono-Bold"

    static var storedFamily: FontFamilyOption {
        let raw = UserDefaults.standard.string(forKey: "fontFamily") ?? "mono"
        return FontFamilyOption(rawValue: raw) ?? .mono
    }

    static var markdownFontName: String {
        switch storedFamily {
        case .mono:
            return preferredMonoFontName(weight: .regular) ?? "SFMono-Regular"
        case .system:
            return ".AppleSystemUIFont"
        }
    }

    static func styled(
        _ style: Font.TextStyle,
        weight: Font.Weight = .regular,
        scale: CGFloat = 1.0
    ) -> Font {
        let pointSize = UIFont.preferredFont(forTextStyle: style.uiTextStyle).pointSize * scale
        return styled(size: pointSize, weight: weight, relativeTo: style)
    }

    static func styled(size: CGFloat, weight: Font.Weight = .regular, scale: CGFloat = 1.0) -> Font {
        styled(size: size * scale, weight: weight, relativeTo: nil)
    }

    static func monospaced(
        _ style: Font.TextStyle,
        weight: Font.Weight = .regular,
        scale: CGFloat = 1.0
    ) -> Font {
        let pointSize = UIFont.preferredFont(forTextStyle: style.uiTextStyle).pointSize * scale
        return monoFont(size: pointSize, weight: weight, relativeTo: style)
    }

    static func monospaced(size: CGFloat, weight: Font.Weight = .regular, scale: CGFloat = 1.0) -> Font {
        monoFont(size: size * scale, weight: weight, relativeTo: nil)
    }

    private static func styled(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle?) -> Font {
        if storedFamily.isMono {
            return monoFont(size: size, weight: weight, relativeTo: style)
        }
        return .system(size: size, weight: weight)
    }

    private static func monoFont(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle?) -> Font {
        if let fontName = preferredMonoFontName(weight: weight) {
            if let style {
                return .custom(fontName, size: size, relativeTo: style)
            }
            return .custom(fontName, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    private static func preferredMonoFontName(weight: Font.Weight) -> String? {
        let preferred = isBold(weight: weight) ? berkeleyBold : berkeleyRegular
        if UIFont(name: preferred, size: 12) != nil {
            return preferred
        }
        if UIFont(name: berkeleyRegular, size: 12) != nil {
            return berkeleyRegular
        }
        return nil
    }

    private static func isBold(weight: Font.Weight) -> Bool {
        switch weight {
        case .semibold, .bold, .heavy, .black:
            return true
        default:
            return false
        }
    }

    static func uiMonoFont(size: CGFloat, bold: Bool = false) -> UIFont {
        let name = bold
            ? preferredMonoFontName(weight: .bold) ?? "SFMono-Bold"
            : preferredMonoFontName(weight: .regular) ?? "SFMono-Regular"
        return UIFont(name: name, size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    static func sampleFont(family: FontFamilyOption, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if family.isMono {
            return monoFont(size: size, weight: weight, relativeTo: nil)
        }
        return .system(size: size, weight: weight)
    }

    static var conversationBodyPointSize: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).pointSize
    }

    static var conversationDiffPointSize: CGFloat {
        UIFont.preferredFont(forTextStyle: .caption1).pointSize
    }
}

// MARK: - App-Wide Text Scaling

enum ConversationTextSize: Int, CaseIterable {
    case tiny = 0
    case small = 1
    case medium = 2
    case large = 3
    case larger = 4
    case xLarge = 5
    case huge = 6

    var scale: CGFloat {
        switch self {
        case .tiny:     return 0.65
        case .small:    return 0.8
        case .medium:   return 1.0
        case .large:    return 1.2
        case .larger:   return 1.4
        case .xLarge:   return 1.6
        case .huge:     return 1.8
        }
    }

    var label: String {
        switch self {
        case .tiny:     return "Tiny"
        case .small:    return "Small"
        case .medium:   return "Medium"
        case .large:    return "Large"
        case .larger:   return "Larger"
        case .xLarge:   return "X-Large"
        case .huge:     return "Huge"
        }
    }

    static func clamped(rawValue: Int) -> ConversationTextSize {
        let bounded = min(max(rawValue, tiny.rawValue), huge.rawValue)
        return ConversationTextSize(rawValue: bounded) ?? .large
    }
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

// MARK: - Auto-Scaling Font View Modifiers

extension View {
    func litterFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledSizeFontModifier(size: size, weight: weight))
    }

    func litterFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledStyleFontModifier(style: style, weight: weight))
    }

    func litterMonoFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledMonoFontModifier(size: size, weight: weight))
    }
}

private struct ScaledSizeFontModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    // Observe so SwiftUI re-evaluates this modifier when the user toggles
    // mono ↔ system in Settings; LitterFont.styled reads storedFamily, so
    // the actual font value still comes from there.
    @AppStorage("fontFamily") private var fontFamily = FontFamilyOption.mono.rawValue
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        let _ = fontFamily
        return content.font(LitterFont.styled(size: size, weight: weight, scale: textScale))
    }
}

private struct ScaledStyleFontModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    @AppStorage("fontFamily") private var fontFamily = FontFamilyOption.mono.rawValue
    let style: Font.TextStyle
    let weight: Font.Weight

    func body(content: Content) -> some View {
        let _ = fontFamily
        return content.font(LitterFont.styled(style, weight: weight, scale: textScale))
    }
}

private struct ScaledMonoFontModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(LitterFont.monospaced(size: size, weight: weight, scale: textScale))
    }
}

private extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }
}

func serverIconName(for server: DiscoveredServer) -> String {
    if server.source == .local { return "iphone" }

    if let os = server.os?.lowercased() {
        if os.contains("windows") { return "pc" }
        if os.contains("raspbian") { return "cpu" }
        if os.contains("ubuntu") || os.contains("debian")
            || os.contains("fedora") || os.contains("red hat")
            || os.contains("freebsd") || os.contains("linux") { return "server.rack" }
    }

    switch server.source {
    case .local: return "iphone"
    case .bonjour: return "macbook"
    case .ssh: return "terminal"
    case .tailscale: return "network"
    case .manual: return "server.rack"
    }
}

func abbreviateHomePath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "~" }
    for basePrefix in ["/Users", "/home"] {
        let prefix = basePrefix + "/"
        guard trimmed.hasPrefix(prefix) else { continue }
        let remainder = trimmed.dropFirst(prefix.count)
        guard let slashIndex = remainder.firstIndex(of: "/") else { return "~" }
        return "~" + remainder[slashIndex...]
    }
    return trimmed
}

func relativeDate(_ timestamp: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - Glass Effect Availability Wrappers

struct GlassRectModifier: ViewModifier {
    let cornerRadius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content
                .background(LitterTheme.surfaceLight.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke((tint ?? LitterTheme.border).opacity(0.4), lineWidth: 1)
                )
        }
    }
}

struct GlassRoundedRectModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(LitterTheme.surfaceLight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct GlassCapsuleModifier: ViewModifier {
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: .capsule)
            } else {
                content.glassEffect(.regular, in: .capsule)
            }
        } else {
            content
                .background(LitterTheme.surfaceLight)
                .clipShape(Capsule())
        }
    }
}

struct GlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .circle)
        } else {
            content
                .background(LitterTheme.surfaceLight)
                .clipShape(Circle())
        }
    }
}

/// Wraps its children in iOS 26's `GlassEffectContainer` when available so
/// views with matching `glassMorphID`s blob between each other with a real
/// liquid-glass transition. On older iOS it's a pass-through.
struct GlassMorphContainer<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

extension View {
    /// Applies iOS 26's `glassEffectID` — which morphs glass between matched
    /// views inside a `GlassEffectContainer` — or falls back to
    /// `matchedGeometryEffect` so the frame still tweens on older iOS.
    @ViewBuilder
    func glassMorphID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self.matchedGeometryEffect(id: id, in: namespace)
        }
    }
}
