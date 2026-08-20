import SwiftUI
import UIKit
import Observation

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
    private static var colorScheme: ColorScheme { ThemeStore.shared.colorScheme }

    static func adaptive(light: String, dark: String) -> Color {
        Color(hex: colorScheme == .dark ? dark : light)
    }

    /// Slug of the theme currently supplying colors, i.e. the light or dark
    /// resolved theme depending on the active color scheme.
    ///
    /// Caches that bake resolved colors into a stored value (see
    /// `MarkdownThemeCache`) key on this so they drop when the theme changes.
    /// It reads through `ThemeStore`, which is `@Observable`, so a read from a
    /// view body also registers the dependency that repaints on theme switch.
    static var activeThemeSlug: String {
        colorScheme == .dark ? dark.slug : light.slug
    }

    static var accent: Color        { adaptive(light: light.accent, dark: dark.accent) }
    static var accentStrong: Color   { adaptive(light: light.accentStrong, dark: dark.accentStrong) }
    static var linkColor: Color {
        adaptive(
            light: chromaticHex(light.accent, fallback: "#0A66C2"),
            dark: chromaticHex(dark.accent, fallback: "#6CB2FF")
        )
    }

    private static func chromaticHex(_ hexColor: String, fallback: String) -> String {
        let hex = hexColor.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF)
        let g = Double((int >> 8) & 0xFF)
        let b = Double(int & 0xFF)
        let maxChannel = max(r, g, b)
        let saturation = maxChannel == 0 ? 0 : (maxChannel - min(r, g, b)) / maxChannel
        return saturation < 0.15 ? fallback : hexColor
    }
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

    static var overlayScrim: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.5)
            : Color.black.opacity(0.3)
    }

    static var gradientColors: [Color] {
        [
            adaptive(light: light.background, dark: dark.background),
            adaptive(
                light: ResolvedTheme.adjustBrightness(light.background, by: -0.01),
                dark: ResolvedTheme.adjustBrightness(dark.background, by: 0.02)
            ),
            adaptive(
                light: ResolvedTheme.adjustBrightness(light.background, by: 0.01),
                dark: ResolvedTheme.adjustBrightness(dark.background, by: -0.01)
            ),
        ]
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
        let bgColor = adaptive(light: light.background, dark: dark.background)
        return [bgColor.opacity(0.7), bgColor.opacity(0.3), .clear]
    }
}

enum FontFamilyOption: String, CaseIterable, Identifiable {
    case mono = "mono"
    case system = "system"
    case systemMono = "system-mono"
    case serif = "serif"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mono: return "Berkeley Mono"
        case .system: return "ChatGPT (System)"
        case .systemMono: return "System Mono"
        case .serif: return "Reader Serif"
        }
    }

    var isMono: Bool { self == .mono || self == .systemMono }
}

/// Makes app-wide SwiftUI font modifiers observe a preference change without
/// recreating the navigation hierarchy or disrupting an active conversation.
@Observable
final class FontPreferenceObserver {
    static let shared = FontPreferenceObserver()

    private(set) var revision = 0

    func didChange() {
        revision &+= 1
    }
}

private struct FontPreferenceObserverKey: EnvironmentKey {
    static let defaultValue = FontPreferenceObserver.shared
}

extension EnvironmentValues {
    var fontPreferenceObserver: FontPreferenceObserver {
        get { self[FontPreferenceObserverKey.self] }
        set { self[FontPreferenceObserverKey.self] = newValue }
    }
}

enum LitterFont {
    private static let berkeleyRegular = "BerkeleyMono-Regular"
    private static let berkeleyBold = "BerkeleyMono-Bold"

    static var storedFamily: FontFamilyOption {
        let raw = UserDefaults.standard.string(forKey: "fontFamily") ?? FontFamilyOption.system.rawValue
        return FontFamilyOption(rawValue: raw) ?? .system
    }

    static var codeFontName: String {
        let name = storedFamily == .mono
            ? preferredMonoFontName(weight: .regular) ?? "SFMono-Regular"
            : "SFMono-Regular"
        return UIFont(name: name, size: conversationBodyPointSize)?.fontName
            ?? UIFont.monospacedSystemFont(ofSize: conversationBodyPointSize, weight: .regular).fontName
    }

    /// Hairball receives a SwiftUI `Font`, not an internal UIKit font name.
    /// Passing the latter through `Font.custom` turns the system selection
    /// into a serif fallback on iOS 26. Keeping this as a real system/design
    /// font makes conversation prose match the rest of the app.
    static func markdownBodyFont(size: CGFloat) -> Font {
        font(family: storedFamily, size: size, weight: .regular, relativeTo: nil)
    }

    static func markdownHeadingFont(size: CGFloat, weight: Font.Weight) -> Font {
        font(family: storedFamily, size: size, weight: weight, relativeTo: nil)
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
        font(family: storedFamily, size: size, weight: weight, relativeTo: style)
    }

    private static func monoFont(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle?) -> Font {
        let family: FontFamilyOption = storedFamily == .mono ? .mono : .systemMono
        return font(family: family, size: size, weight: weight, relativeTo: style)
    }

    private static func font(
        family: FontFamilyOption,
        size: CGFloat,
        weight: Font.Weight,
        relativeTo style: Font.TextStyle?
    ) -> Font {
        if family == .mono, let fontName = preferredMonoFontName(weight: weight) {
            if let style {
                return .custom(fontName, size: size, relativeTo: style)
            }
            return .custom(fontName, size: size)
        }

        let design: Font.Design
        switch family {
        case .mono, .systemMono:
            design = .monospaced
        case .system:
            design = .default
        case .serif:
            design = .serif
        }
        return .system(size: size, weight: weight, design: design)
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
        if storedFamily == .mono {
            let name = bold
                ? preferredMonoFontName(weight: .bold) ?? "SFMono-Bold"
                : preferredMonoFontName(weight: .regular) ?? "SFMono-Regular"
            if let font = UIFont(name: name, size: size) {
                return font
            }
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    static func uiFont(size: CGFloat, bold: Bool = false) -> UIFont {
        uiFont(family: storedFamily, size: size, bold: bold)
    }

    private static func uiFont(family: FontFamilyOption, size: CGFloat, bold: Bool = false) -> UIFont {
        let weight: UIFont.Weight = bold ? .bold : .regular
        switch family {
        case .mono:
            let name = bold
                ? preferredMonoFontName(weight: .bold) ?? "SFMono-Bold"
                : preferredMonoFontName(weight: .regular) ?? "SFMono-Regular"
            return UIFont(name: name, size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .system:
            return UIFont.systemFont(ofSize: size, weight: weight)
        case .systemMono:
            return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .serif:
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }
    }

    static func sampleFont(family: FontFamilyOption, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(family: family, size: size, weight: weight, relativeTo: nil)
    }

    static var conversationBodyPointSize: CGFloat {
        // The system body metric follows Dynamic Type. Keep chat deliberately
        // one point tighter than a settings/form screen so long assistant
        // replies stay comfortable rather than reading like accessibility
        // display text on a phone.
        max(UIFont.preferredFont(forTextStyle: .body).pointSize - 1, 15)
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
        return ConversationTextSize(rawValue: bounded) ?? .medium
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
    @Environment(\.fontPreferenceObserver) private var fontPreferenceObserver
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content
            .font(LitterFont.styled(size: size, weight: weight, scale: textScale))
            .id(fontPreferenceObserver.revision)
    }
}

private struct ScaledStyleFontModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    @Environment(\.fontPreferenceObserver) private var fontPreferenceObserver
    let style: Font.TextStyle
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content
            .font(LitterFont.styled(style, weight: weight, scale: textScale))
            .id(fontPreferenceObserver.revision)
    }
}

private struct ScaledMonoFontModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    @Environment(\.fontPreferenceObserver) private var fontPreferenceObserver
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content
            .font(LitterFont.monospaced(size: size, weight: weight, scale: textScale))
            .id(fontPreferenceObserver.revision)
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

private let cachedRelativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

func relativeDate(_ timestamp: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    return cachedRelativeDateFormatter.localizedString(for: date, relativeTo: Date())
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

extension URL {
    var isWebLink: Bool {
        let scheme = scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}

extension OpenURLAction {
    static var externalBrowser: OpenURLAction {
        OpenURLAction { url in
            guard url.isWebLink else { return .systemAction }
            UIApplication.shared.open(url)
            return .handled
        }
    }
}

enum MessageLinks {
    static let detector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func links(in text: String, limit: Int = 5) -> [URL] {
        guard text.contains("://") || text.lowercased().contains("www."),
              let detector else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var links: [URL] = []
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url,
                  url.isWebLink,
                  seen.insert(url.absoluteString).inserted else { continue }
            links.append(url)
            if links.count >= limit { break }
        }
        return links
    }

    static func copyTitle(for url: URL) -> String {
        let display = url.host.map { host in
            url.path.count > 1 ? "\(host)\(url.path)" : host
        } ?? url.absoluteString
        let trimmed = display.count > 40 ? String(display.prefix(40)) + "…" : display
        return "Copy \(trimmed)"
    }
}
