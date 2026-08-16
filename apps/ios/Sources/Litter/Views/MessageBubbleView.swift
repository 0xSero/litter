import SwiftUI
import Hairball
import HairballUI
import Nuke
import NukeUI
import UIKit

extension View {
    @ViewBuilder
    func applyStreamingEffect(_ effect: (any StreamingTextEffect)?) -> some View {
        if let effect {
            self.streamingTextEffect(effect)
        } else {
            self
        }
    }
}

// MARK: - Active Thread Key Environment

private struct ActiveThreadKeyKey: EnvironmentKey {
    static let defaultValue: ThreadKey? = nil
}

extension EnvironmentValues {
    var activeThreadKey: ThreadKey? {
        get { self[ActiveThreadKeyKey.self] }
        set { self[ActiveThreadKeyKey.self] = newValue }
    }
}

extension View {
    func activeThreadKey(_ key: ThreadKey?) -> some View {
        environment(\.activeThreadKey, key)
    }
}

// MARK: - Reusable bubble components

enum LitterMarkdownStyleVariant {
    case content
    case system
}

struct LitterMarkdownView: View {
    let markdown: String
    var style: LitterMarkdownStyleVariant = .content
    var bodySize: CGFloat = LitterFont.conversationBodyPointSize
    var codeSize: CGFloat = LitterFont.conversationBodyPointSize
    var selectionEnabled = true

    @State private var debugSettings = DebugSettings.shared
    @Environment(\.fontPreferenceObserver) private var fontPreferenceObserver

    var body: some View {
        if debugSettings.enabled && debugSettings.disableMarkdown {
            Text(markdown)
                .font(LitterFont.markdownBodyFont(size: bodySize))
                .foregroundColor(style == .system ? LitterTheme.textSecondary : LitterTheme.textPrimary)
                .textSelection(.enabled)
        } else {
            renderedMarkdown(selectionEnabled: selectionEnabled)
                .id(fontPreferenceObserver.revision)
        }
    }

    @ViewBuilder
    private func renderedMarkdown(selectionEnabled: Bool) -> some View {
        let view = MarkdownView(markdown, processors: [LatexTransformer()])
        switch style {
        case .content:
            view.litterContentMarkdown(
                bodySize: bodySize, codeSize: codeSize,
                selectionEnabled: selectionEnabled
            )
            .environment(\.openURL, externalBrowserAction)
        case .system:
            view.litterSystemMarkdown(
                bodySize: bodySize, codeSize: codeSize,
                selectionEnabled: selectionEnabled
            )
            .environment(\.openURL, externalBrowserAction)
        }
    }

    private var externalBrowserAction: OpenURLAction {
        OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return .systemAction
            }
            UIApplication.shared.open(url)
            return .handled
        }
    }
}

struct InlineSelectableMarkdownMessage<Content: View>: View {
    let markdown: String
    var style: LitterMarkdownStyleVariant = .content
    var bodySize: CGFloat = LitterFont.conversationBodyPointSize
    var codeSize: CGFloat = LitterFont.conversationBodyPointSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private extension LitterMarkdownStyleVariant {
    var cacheKey: String {
        switch self {
        case .content:
            return "content"
        case .system:
            return "system"
        }
    }
}

struct UserBubble: View {
    let text: String
    var images: [ChatImage] = []
    var compact: Bool = false
    var maxVisibleCharacters: Int = 1_000
    @State private var expandedLongText = false
    private let contentFontSize = LitterFont.conversationBodyPointSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: compact ? 30 : 60)
            VStack(alignment: .trailing, spacing: compact ? 4 : 8) {
                ForEach(images) { img in
                    if let request = UserBubble.imageRequest(for: img) {
                        LazyImage(request: request) { state in
                            if let image = state.image {
                                if let ui = state.imageContainer?.image {
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: 200, maxHeight: 200)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .draggable(Image(uiImage: ui)) {
                                            Image(uiImage: ui)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 120)
                                        }
                                } else {
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: 200, maxHeight: 200)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }
                if !text.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        FormattedText(text: visibleText)
                            .litterFont(size: contentFontSize)
                            .foregroundColor(LitterTheme.textPrimary)
                            .textSelection(.enabled)

                        if shouldLimitText {
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    expandedLongText.toggle()
                                }
                            } label: {
                                Text(expandedLongText ? "Show less" : "Show more")
                                    .litterFont(.caption2, weight: .semibold)
                                    .foregroundColor(LitterTheme.accent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(expandedLongText ? "Show less user message" : "Show more user message")
                        }
                    }
                }
            }
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 8 : 14)
            .modifier(GlassRectModifier(cornerRadius: compact ? 14 : 18, tint: LitterTheme.accent.opacity(0.3)))
        }
        .padding(.bottom, 14)
        .onChange(of: text) { _, _ in
            expandedLongText = false
        }
    }

    private var visibleText: String {
        guard shouldLimitText, !expandedLongText else {
            return text
        }
        return String(text.prefix(maxVisibleCharacters))
    }

    private var shouldLimitText: Bool {
        text.count > maxVisibleCharacters
    }

    fileprivate static func imageRequest(for image: ChatImage) -> ImageRequest? {
        let source = image.source
        guard source.hasPrefix("data:") || source.hasPrefix("file://") else {
            return nil
        }
        let cacheKey = image.cacheKey
        let processors: [any ImageProcessing] = [
            ImageProcessors.Resize(
                size: CGSize(width: 200, height: 200),
                unit: .points,
                contentMode: .aspectFit
            )
        ]
        return ImageRequest(
            id: cacheKey,
            data: { @Sendable in
                guard let data = imageData(forSource: source) else {
                    throw URLError(.fileDoesNotExist)
                }
                return data
            },
            processors: processors
        )
    }

    private nonisolated static func imageData(forSource source: String) -> Data? {
        if source.hasPrefix("file://") {
            let path = String(source.dropFirst("file://".count))
            return FileManager.default.contents(atPath: path)
        }
        guard let commaIndex = source.firstIndex(of: ",") else { return nil }
        let base64 = String(source[source.index(after: commaIndex)...])
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }
}

struct AssistantBubble: View, Equatable {
    let markdownString: String
    let markdownIdentity: Int
    var label: String? = nil
    var compact: Bool = false
    var allowsInlineSelection: Bool = true
    private let contentFontSize = LitterFont.conversationBodyPointSize

    init(
        text: String,
        label: String? = nil,
        compact: Bool = false,
        allowsInlineSelection: Bool = true
    ) {
        self.markdownString = text
        self.markdownIdentity = text.hashValue
        self.label = label
        self.compact = compact
        self.allowsInlineSelection = allowsInlineSelection
    }

    init(
        markdownString: String,
        markdownIdentity: Int,
        label: String? = nil,
        compact: Bool = false,
        allowsInlineSelection: Bool = true
    ) {
        self.markdownString = markdownString
        self.markdownIdentity = markdownIdentity
        self.label = label
        self.compact = compact
        self.allowsInlineSelection = allowsInlineSelection
    }

    static func == (lhs: AssistantBubble, rhs: AssistantBubble) -> Bool {
        lhs.markdownIdentity == rhs.markdownIdentity &&
        lhs.label == rhs.label &&
        lhs.compact == rhs.compact &&
        lhs.allowsInlineSelection == rhs.allowsInlineSelection
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if allowsInlineSelection {
                InlineSelectableMarkdownMessage(
                    markdown: markdownString,
                    style: .content,
                    bodySize: contentFontSize,
                    codeSize: contentFontSize
                ) {
                    bubbleContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                bubbleContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: compact ? 8 : 20)
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            if let label {
                Text(label)
                    .litterFont(.caption2, weight: .semibold)
                    .foregroundColor(LitterTheme.textSecondary)
            }
            LitterMarkdownView(
                markdown: markdownString,
                style: .content,
                bodySize: contentFontSize,
                codeSize: contentFontSize
            )
            .fixedSize(horizontal: false, vertical: true)
            .transaction { $0.animation = nil }
        }
    }
}

struct AssistantBlocksBubble: View {
    let segments: [MessageRenderCache.AssistantSegment]
    var label: String? = nil
    var compact: Bool = false
    private let contentFontSize = LitterFont.conversationBodyPointSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                if let label {
                    Text(label)
                        .litterFont(.caption2, weight: .semibold)
                        .foregroundColor(LitterTheme.textSecondary)
                }

                ForEach(segments) { segment in
                    segmentView(segment)
                        .transition(.asymmetric(
                            insertion: .push(from: .top),
                            removal: .identity
                        ))
                }
            }
            .transaction { $0.animation = nil }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: compact ? 8 : 20)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MessageRenderCache.AssistantSegment) -> some View {
        switch segment.kind {
        case .markdown(let content, let identity):
            LitterMarkdownView(
                markdown: content,
                style: .content,
                bodySize: contentFontSize,
                codeSize: contentFontSize
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(identity)
        case .codeBlock(let language, let code, let identity):
            if isMathCodeBlock(language) {
                LitterMathBlockView(latex: code)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(identity)
            } else {
                CodeBlockView(
                    language: language ?? "",
                    code: code,
                    fontSize: contentFontSize
                )
                .id(identity)
            }
        case .image(let data, let cacheKey):
            ResolvedChatImageView(
                source: .data(data),
                maxHeight: 300
            )
            .id(cacheKey)
        case .localImage(let path, let cacheKey):
            ResolvedChatImageView(
                source: .path(path),
                maxHeight: 320
            )
            .id(cacheKey)
        }
    }

    private func isMathCodeBlock(_ language: String?) -> Bool {
        guard let language else { return false }
        return language.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("math") == .orderedSame
    }
}

private struct LitterMathBlockView: View {
    let latex: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LatexBlockView(content: latex)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StreamingAssistantBubble: View {
    @Environment(WallpaperManager.self) private var wallpaperManager
    @Environment(\.activeThreadKey) private var threadKey
    let itemId: String
    let text: String
    var isStreaming: Bool = false
    var label: String? = nil
    var onSnapshotRendered: (() -> Void)? = nil
    private let contentFontSize: CGFloat

    /// Renderer is resolved once during init. For streaming items, this
    /// creates the renderer eagerly (before deltas arrive) so the `if let`
    /// branch is taken on the very first body evaluation. The coordinator
    /// returns the same renderer when deltas later call `appendDelta`.
    private let resolvedRenderer: StreamingMarkdownRenderer?

    init(
        itemId: String,
        text: String,
        isStreaming: Bool = false,
        label: String? = nil,
        bodySize: CGFloat = LitterFont.conversationBodyPointSize,
        onSnapshotRendered: (() -> Void)? = nil
    ) {
        self.itemId = itemId
        self.text = text
        self.isStreaming = isStreaming
        self.label = label
        self.contentFontSize = bodySize
        self.onSnapshotRendered = onSnapshotRendered

        let coord = StreamingRendererCoordinator.shared
        if isStreaming {
            self.resolvedRenderer = coord.renderer(for: itemId, currentText: text)
        } else {
            self.resolvedRenderer = nil
        }
    }

    private var typingConfig: TypingEffectConfig {
        wallpaperManager.resolveTypingEffect(for: threadKey)
    }

    var body: some View {
        Group {
            if shouldUseSegmentedRenderer {
                AssistantBlocksBubble(
                    segments: segmentedRenderSegments,
                    label: label
                )
            } else {
                streamingMarkdownBody
            }
        }
        .onChange(of: text) {
            onSnapshotRendered?()
        }
    }

    private var shouldUseSegmentedRenderer: Bool {
        !isStreaming || StreamingMathDetectionCache.shared.containsMath(itemId: itemId, text: text)
    }

    private var segmentedRenderSegments: [MessageRenderCache.AssistantSegment] {
        StreamingAssistantRenderCache.shared.segments(itemId: itemId, text: text)
    }

    private var streamingMarkdownBody: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let label {
                    Text(label)
                        .litterFont(.caption2, weight: .semibold)
                        .foregroundColor(LitterTheme.textSecondary)
                }
                if let resolvedRenderer {
                    StreamingMarkdownContentView(renderer: resolvedRenderer)
                        .tokenReveal(TokenRevealConfig(duration: max(typingConfig.revealDuration, 0.01), mode: typingConfig.effectiveRevealMode))
                        .applyStreamingEffect(typingConfig.resolvedEffect)
                        .revealGranularity(typingConfig.effectiveGranularity)
                        .litterContentMarkdown(
                            bodySize: contentFontSize,
                            codeSize: contentFontSize,
                            selectionEnabled: !isStreaming
                        )
                        .transaction { $0.animation = nil }
                } else {
                    LitterMarkdownView(
                        markdown: text,
                        style: .content,
                        bodySize: contentFontSize,
                        codeSize: contentFontSize
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .tokenReveal(.disabled)
                    .transaction { $0.animation = nil }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 20)
        }
    }
}

// MARK: - Streaming Math Detection

/// Caches `MessageContentBridge.containsMath` for the live streaming message.
///
/// `containsMath` is a synchronous Rust FFI call that parses the whole message.
/// Calling it from `body` on a message that keeps growing made the live turn
/// quadratic in its own length.
///
/// The Rust math segmenter (`find_math_spans`) only opens or closes a math span
/// at a `$` or a `\` byte, and every closing delimiter (`$`, `$$`, `\]`, `\)`)
/// contains one of those bytes. So while a message is only being appended to,
/// math can *newly appear* only if the appended tail contains `$` or `\`. That
/// makes the per-tick cost O(appended bytes) instead of O(message length), with
/// no detection delay for real math.
@MainActor
private final class StreamingMathDetectionCache {
    static let shared = StreamingMathDetectionCache()

    private struct Entry {
        var scannedUTF8Count: Int
        var result: Bool
    }

    private let maxEntries = 64
    private let trimTarget = 48

    private var entries: [String: Entry] = [:]
    private var accessStamps: [String: UInt64] = [:]
    private var accessCounter: UInt64 = 0

    func containsMath(itemId: String, text: String) -> Bool {
        let utf8Count = text.utf8.count

        if let entry = entries[itemId] {
            if utf8Count == entry.scannedUTF8Count {
                touch(itemId)
                return entry.result
            }
            if utf8Count > entry.scannedUTF8Count {
                // Math never un-appears from an append-only stream, and a new
                // span needs a trigger byte in the appended tail.
                if entry.result {
                    entries[itemId] = Entry(scannedUTF8Count: utf8Count, result: true)
                    touch(itemId)
                    return true
                }
                let appended = utf8Count - entry.scannedUTF8Count
                // +2 bytes of overlap so a `\[` / `\]` straddling the boundary
                // is still seen.
                if !Self.tailContainsMathTrigger(text, tailByteCount: appended + 2) {
                    entries[itemId] = Entry(scannedUTF8Count: utf8Count, result: false)
                    touch(itemId)
                    return false
                }
            }
        }

        let result = MessageContentBridge.containsMath(text)
        entries[itemId] = Entry(scannedUTF8Count: utf8Count, result: result)
        touch(itemId)
        trimIfNeeded()
        return result
    }

    func reset() {
        entries.removeAll(keepingCapacity: false)
        accessStamps.removeAll(keepingCapacity: false)
        accessCounter = 0
    }

    private static func tailContainsMathTrigger(_ text: String, tailByteCount: Int) -> Bool {
        guard tailByteCount > 0 else { return false }
        var remaining = tailByteCount
        for byte in text.utf8.reversed() {
            if byte == UInt8(ascii: "$") || byte == UInt8(ascii: "\\") { return true }
            remaining -= 1
            if remaining == 0 { break }
        }
        return false
    }

    private func touch(_ itemId: String) {
        accessCounter &+= 1
        accessStamps[itemId] = accessCounter
    }

    private func trimIfNeeded() {
        guard entries.count > maxEntries else { return }
        let removeCount = entries.count - trimTarget
        guard removeCount > 0 else { return }
        for (key, _) in accessStamps.sorted(by: { $0.value < $1.value }).prefix(removeCount) {
            entries.removeValue(forKey: key)
            accessStamps.removeValue(forKey: key)
        }
    }
}

// MARK: - Litter Markdown Themes

/// Memoizes the two `MarkdownTheme` builders.
///
/// Each build constructed ~10 fonts plus a `HeadingStyleSet`, an
/// `InlineCodeStyle`, a `CodeBlockStyle`, a `TableStyle` and friends — and ran
/// once per markdown view per render pass.
@MainActor
private final class MarkdownThemeCache {
    static let shared = MarkdownThemeCache()

    fileprivate struct Key: Hashable {
        let bodySize: CGFloat
        let codeSize: CGFloat
        let isDark: Bool
        let themeVersion: Int
        let fontRevision: Int
    }

    private var contentThemes: [Key: MarkdownTheme] = [:]
    private var systemThemes: [Key: MarkdownTheme] = [:]
    private var lastThemeVersion: Int?
    private var lastFontRevision: Int?

    fileprivate func contentTheme(_ key: Key, build: () -> MarkdownTheme) -> MarkdownTheme {
        invalidateIfNeeded(key)
        if let cached = contentThemes[key] { return cached }
        let theme = build()
        contentThemes[key] = theme
        return theme
    }

    fileprivate func systemTheme(_ key: Key, build: () -> MarkdownTheme) -> MarkdownTheme {
        invalidateIfNeeded(key)
        if let cached = systemThemes[key] { return cached }
        let theme = build()
        systemThemes[key] = theme
        return theme
    }

    /// Theme/font revisions bump rarely; dropping everything on a bump keeps
    /// the caches bounded without an LRU (the only other key axes are the two
    /// point sizes and the color scheme, so a live generation stays tiny).
    private func invalidateIfNeeded(_ key: Key) {
        guard lastThemeVersion != key.themeVersion || lastFontRevision != key.fontRevision else { return }
        lastThemeVersion = key.themeVersion
        lastFontRevision = key.fontRevision
        contentThemes.removeAll(keepingCapacity: true)
        systemThemes.removeAll(keepingCapacity: true)
    }
}

private func litterContentTheme(bodySize: CGFloat, codeSize: CGFloat) -> MarkdownTheme {
    var theme = MarkdownTheme.default
    theme.bodyFont = LitterFont.markdownBodyFont(size: bodySize)
    theme.bodyFontSize = bodySize
    // Conversation prose is the reading surface. Keep it at the theme's
    // primary foreground rather than the muted metadata color so long replies
    // retain contrast on dark themes.
    theme.foregroundColor = LitterTheme.textPrimary
    theme.paragraphSpacing = 8
    theme.blockSpacing = 8

    theme.headingStyleSet = HeadingStyleSet(
        h1: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize * 1.43, weight: .bold), fontSize: bodySize * 1.43, weight: .bold,
                         topSpacing: 16, bottomSpacing: 8, color: LitterTheme.textPrimary),
        h2: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize * 1.21, weight: .semibold), fontSize: bodySize * 1.21, weight: .semibold,
                         topSpacing: 12, bottomSpacing: 6, color: LitterTheme.textPrimary),
        h3: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize * 1.07, weight: .semibold), fontSize: bodySize * 1.07, weight: .semibold,
                         topSpacing: 10, bottomSpacing: 4, color: LitterTheme.textPrimary),
        h4: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize, weight: .semibold), fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary),
        h5: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize, weight: .semibold), fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary),
        h6: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize, weight: .semibold), fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary)
    )

    theme.inlineCode = InlineCodeStyle(
        backgroundColor: LitterTheme.surfaceLight,
        textColor: LitterTheme.textPrimary,
        font: .custom(LitterFont.codeFontName, size: codeSize),
        fontSize: codeSize
    )

    theme.codeBlock = CodeBlockStyle(
        backgroundColor: LitterTheme.codeBackground.opacity(0.8),
        textColor: LitterTheme.textPrimary,
        font: .custom(LitterFont.codeFontName, size: codeSize),
        fontSize: codeSize,
        cornerRadius: 8,
        showLanguageLabel: false,
        showCopyButton: false
    )

    theme.blockquote = BlockquoteStyle(
        borderColor: LitterTheme.border,
        borderWidth: 3,
        textColor: LitterTheme.textSecondary,
        padding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 4)
    )

    theme.table = TableStyle(
        borderStyle: .solid(color: LitterTheme.border, width: 0.5),
        headerBackground: LitterTheme.surfaceLight,
        headerFontWeight: .semibold,
        backgroundStyle: .alternatingRows(
            even: LitterTheme.surface.opacity(0.5),
            odd: .clear
        ),
        cellConfiguration: TableCellConfiguration(horizontalPadding: 10, verticalPadding: 6),
        fontSize: bodySize,
        verticalMargin: 10,
        cornerRadius: 8
    )

    theme.list = ListStyleConfiguration(
        bulletMarker: .bullet,
        itemSpacing: 4,
        tightItemSpacing: 4
    )

    theme.link = LinkStyle(color: LitterTheme.accent, underline: false)

    theme.thematicBreak = ThematicBreakStyle(
        color: LitterTheme.border,
        verticalPadding: 12
    )

    return theme
}

private func litterSystemTheme(bodySize: CGFloat, codeSize: CGFloat) -> MarkdownTheme {
    var theme = MarkdownTheme.default
    theme.bodyFont = LitterFont.markdownBodyFont(size: bodySize)
    theme.bodyFontSize = bodySize
    theme.foregroundColor = LitterTheme.textSystem
    theme.paragraphSpacing = 6
    theme.blockSpacing = 6

    theme.headingStyleSet = HeadingStyleSet(
        h1: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize * 1.31, weight: .bold), fontSize: bodySize * 1.31, weight: .bold,
                         topSpacing: 12, bottomSpacing: 6, color: LitterTheme.textPrimary),
        h2: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize * 1.15, weight: .semibold), fontSize: bodySize * 1.15, weight: .semibold,
                         topSpacing: 10, bottomSpacing: 4, color: LitterTheme.textPrimary),
        h3: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize * 1.08, weight: .semibold), fontSize: bodySize * 1.08, weight: .semibold,
                         topSpacing: 8, bottomSpacing: 4, color: LitterTheme.textPrimary),
        h4: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize, weight: .semibold), fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary),
        h5: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize, weight: .semibold), fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary),
        h6: HeadingStyle(font: LitterFont.markdownHeadingFont(size: bodySize, weight: .semibold), fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary)
    )

    theme.inlineCode = InlineCodeStyle(
        backgroundColor: LitterTheme.surfaceLight,
        textColor: LitterTheme.textPrimary,
        font: .custom(LitterFont.codeFontName, size: codeSize),
        fontSize: codeSize
    )

    theme.codeBlock = CodeBlockStyle(
        backgroundColor: LitterTheme.codeBackground.opacity(0.8),
        textColor: LitterTheme.textPrimary,
        font: .custom(LitterFont.codeFontName, size: codeSize),
        fontSize: codeSize,
        cornerRadius: 8,
        showLanguageLabel: false,
        showCopyButton: false
    )

    theme.blockquote = BlockquoteStyle(
        borderColor: LitterTheme.border,
        borderWidth: 3,
        textColor: LitterTheme.textSecondary,
        padding: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 4)
    )

    theme.table = TableStyle(
        borderStyle: .solid(color: LitterTheme.border, width: 0.5),
        headerBackground: LitterTheme.surfaceLight,
        headerFontWeight: .semibold,
        backgroundStyle: .alternatingRows(
            even: LitterTheme.surface.opacity(0.5),
            odd: .clear
        ),
        cellConfiguration: TableCellConfiguration(horizontalPadding: 10, verticalPadding: 6),
        fontSize: bodySize,
        verticalMargin: 8,
        cornerRadius: 8
    )

    theme.list = ListStyleConfiguration(
        bulletMarker: .bullet,
        itemSpacing: 3,
        tightItemSpacing: 3
    )

    theme.link = LinkStyle(color: LitterTheme.accent, underline: false)

    theme.thematicBreak = ThematicBreakStyle(
        color: LitterTheme.border,
        verticalPadding: 8
    )

    return theme
}

struct LitterCodeBlockRenderer: CodeBlockRenderer {
    @ViewBuilder
    func makeBody(configuration: CodeBlockConfiguration) -> some View {
        if isDiffLanguage(configuration.language) {
            VStack(alignment: .leading, spacing: 0) {
                if configuration.hasLanguage {
                    HStack {
                        Text(configuration.languageDisplayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    SyntaxHighlightedDiffText(
                        diff: configuration.code,
                        fontSize: LitterFont.conversationDiffPointSize
                    )
                    .padding(configuration.theme.codeBlock.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(configuration.theme.codeBlock.backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: configuration.theme.codeBlock.cornerRadius))
            .modifier(GlassRectModifier(cornerRadius: 8))
            .modifier(CodeBlockTerminalContextMenu(code: configuration.code))
        } else {
            DefaultCodeBlockRenderer().makeBody(configuration: configuration)
                .modifier(GlassRectModifier(cornerRadius: 8))
                .modifier(CodeBlockTerminalContextMenu(code: configuration.code))
        }
    }
}

/// Adds a "Run in terminal" + "Copy" context menu to a chat code block.
private struct CodeBlockTerminalContextMenu: ViewModifier {
    let code: String

    /// Resolved on appear rather than inside `body`.
    ///
    /// `store.activeTerminalId()` is a synchronous UniFFI call; reading it from
    /// the `contextMenu` builder meant one main-thread FFI hop per rendered
    /// code block per render pass.
    @State private var hasActiveTerminal = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if hasActiveTerminal {
                    Button {
                        let bytes = Data(code.utf8)
                        Task {
                            _ = try? await AppModel.shared.store.writeToActiveTerminal(bytes: bytes)
                        }
                    } label: {
                        Label("Run in Terminal", systemImage: "terminal")
                    }
                }
            }
            .onAppear {
                hasActiveTerminal = ActiveTerminalAvailability.shared.isAvailable()
            }
    }
}

/// Short-TTL memo over `store.activeTerminalId()` so that scrolling a transcript
/// full of code blocks does not fire one FFI call per block per appearance.
@MainActor
private final class ActiveTerminalAvailability {
    static let shared = ActiveTerminalAvailability()

    private static let ttl: TimeInterval = 2

    private var cachedValue = false
    private var lastCheck: TimeInterval = -.greatestFiniteMagnitude

    func isAvailable() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCheck < Self.ttl { return cachedValue }
        lastCheck = now
        cachedValue = AppModel.shared.store.activeTerminalId() != nil
        return cachedValue
    }
}

// MARK: - Syntax Highlighting Theme Mapping

/// Memoizes Highlightr's JS-based code tokenization.
///
/// `HighlightrCodeSyntaxHighlighter.highlightCode` runs highlight.js through
/// JavaScriptCore — a synchronous, main-thread expensive call that also bakes
/// the current theme's token colors into the result. HairballUI's
/// `CodeBlockBody` calls it inline in `body`, so without memoization the same
/// block is re-tokenized on every SwiftUI re-evaluation (streaming deltas,
/// snapshot updates, scroll layout passes, theme changes).
///
/// The cache is keyed on the full render inputs — `(code, language, themeName)`
/// — the same "compute once per inputs, reuse until they change" pattern the
/// app already uses for diff rendering (`SyntaxHighlightedDiffText`). Because
/// most Litter themes map to a shared Highlightr palette (e.g. the whole
/// "atom-one-dark" family), switching between those themes does not change
/// `themeName`, so the cached tokenization survives the switch and code blocks
/// simply recolor through the theme environment instead of re-running the JS
/// tokenizer.
private final class CachedHighlightrCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private struct Key: Hashable {
        let code: String
        let language: String?
        let themeName: String
    }

    private let inner: HighlightrCodeSyntaxHighlighter
    private let lock = NSLock()
    private var cache: [Key: AttributedString] = [:]
    private var insertionOrder: [Key] = []

    private static let maxEntries = 256

    init(theme: String) {
        self.inner = HighlightrCodeSyntaxHighlighter(theme: theme)
    }

    var themeName: String {
        inner.themeName
    }

    @discardableResult
    func setTheme(_ name: String) -> Bool {
        inner.setTheme(name)
    }

    func highlightCode(_ code: String, language: String?) -> AttributedString {
        let key = Key(code: code, language: language, themeName: inner.themeName)

        lock.lock()
        if let hit = cache[key] {
            touchLocked(key)
            lock.unlock()
            return hit
        }
        lock.unlock()

        let result = inner.highlightCode(code, language: language)

        lock.lock()
        // Guard against caching a result colored by a theme that changed while
        // the JS call was in flight (all current callers are main-thread, so
        // this is defensive).
        if cache[key] == nil && inner.themeName == key.themeName {
            cache[key] = result
            insertionOrder.append(key)
            trimIfNeededLocked()
        }
        lock.unlock()
        return result
    }

    private func touchLocked(_ key: Key) {
        if let index = insertionOrder.firstIndex(of: key) {
            insertionOrder.remove(at: index)
        }
        insertionOrder.append(key)
    }

    private func trimIfNeededLocked() {
        guard cache.count > Self.maxEntries else { return }
        while cache.count > Self.maxEntries * 3 / 4, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}

/// Shared highlighter instance — theme is switched at runtime via `setTheme(_:)`.
private let sharedHighlighter = CachedHighlightrCodeSyntaxHighlighter(theme: "atom-one-dark")

/// Maps a Litter theme slug to the closest Highlightr theme name.
/// Direct matches are checked first, then known family prefixes, then light/dark fallback.
private let highlightrDirectMap: [String: String] = [
    "codex-dark": "atom-one-dark",
    "codex-light": "atom-one-light",
    "dark-plus-B1yOZ-Hy": "vs2015",
    "light-plus": "vs",
    "one-dark-pro-D": "atom-one-dark",
    "material-theme": "material",
    "material-theme-darker-D": "material-darker",
    "material-theme-lighter": "material-lighter",
    "material-theme-ocean": "ocean",
    "material-theme-palenight": "material-palenight",
    "catppuccin-mocha-Ry8aD-5u": "mocha",
    "catppuccin-latte-Bd1wq-gC": "one-light",
    "catppuccin-frappe": "atom-one-dark",
    "catppuccin-macchiato": "atom-one-dark",
    "tokyo-night": "tokyo-night-dark",
    "kanagawa-wave": "atom-one-dark",
    "kanagawa-dragon-VscOyZL-": "atom-one-dark",
    "kanagawa-lotus": "atom-one-light",
    "houston": "atom-one-dark",
    "poimandres": "panda-syntax-dark",
    "vitesse-black": "atom-one-dark",
    "vitesse-dark": "atom-one-dark",
    "vitesse-light": "atom-one-light",
    "linear-dark": "atom-one-dark",
    "linear-light": "atom-one-light",
    "sentry-dark": "atom-one-dark",
    "notion-dark-BTRKJ-yg": "atom-one-dark",
    "notion-light": "atom-one-light",
    "temple-dark": "atom-one-dark",
    "lobster-dark-dxSKfHK-": "atom-one-dark",
    "matrix-dark": "green-screen",
    "absolutely-dark": "atom-one-dark",
    "absolutely-light": "atom-one-light",
    "proof-light": "atom-one-light",
    "pierre-dark": "atom-one-dark",
    "pierre-light": "atom-one-light",
    "slack-dark": "atom-one-dark",
    "slack-ochin-CRg": "atom-one-light",
    "oscurange-C": "atom-one-dark",
    "ayu-dark": "atom-one-dark",
    "laserwave": "shades-of-purple",
    "vesper": "atom-one-dark",
    "min-dark-": "atom-one-dark",
    "min-light": "atom-one-light",
    "snazzy-light": "snazzy",
    "rose-pine-x": "rose-pine",
]

private let highlightrFamilyPrefixes = [
    "dracula", "monokai", "nord", "solarized-dark", "solarized-light",
    "night-owl", "one-light", "github-dark", "github-light",
    "gruvbox-dark-hard", "gruvbox-dark-medium", "gruvbox-dark-soft",
    "gruvbox-light-hard", "gruvbox-light-medium", "gruvbox-light-soft",
    "everforest-dark", "everforest-light",
    "rose-pine-dawn", "rose-pine-moon",
]

private func highlightrThemeName(for slug: String, type: ThemeDefinition.ThemeType) -> String {
    if let mapped = highlightrDirectMap[slug] { return mapped }

    for prefix in highlightrFamilyPrefixes {
        if slug.hasPrefix(prefix) {
            // Highlightr uses the same names for these (ros-pine vs rose-pine handled)
            let hlName = slug
                .replacingOccurrences(of: "github-dark-default", with: "github-dark")
                .replacingOccurrences(of: "github-dark-dimmed", with: "github-dark-dimmed")
                .replacingOccurrences(of: "github-dark-high-contrast", with: "github-dark")
                .replacingOccurrences(of: "github-light-default", with: "github")
                .replacingOccurrences(of: "github-light-high-contrast", with: "github")
                .replacingOccurrences(of: "everforest-dark", with: "atom-one-dark")
                .replacingOccurrences(of: "everforest-light", with: "atom-one-light")
                .replacingOccurrences(of: "rose-pine-dawn", with: "ros-pine-dawn")
                .replacingOccurrences(of: "rose-pine-moon", with: "ros-pine-moon")
            if hlName != slug { return hlName }
            return prefix
        }
    }

    // Fallback: generic dark/light
    return type == .dark ? "atom-one-dark" : "atom-one-light"
}

/// Returns the current Highlightr theme name based on the active Litter theme.
private func currentHighlightrTheme(for colorScheme: ColorScheme) -> String {
    let resolved = colorScheme == .dark ? ThemeStore.shared.dark : ThemeStore.shared.light
    return highlightrThemeName(for: resolved.slug, type: resolved.type)
}

/// Syncs the shared highlighter to match the current Litter theme.
private func syncHighlighterTheme(for colorScheme: ColorScheme) {
    let desired = currentHighlightrTheme(for: colorScheme)
    if sharedHighlighter.themeName != desired {
        sharedHighlighter.setTheme(desired)
    }
}

// MARK: - Auto-Scaling Markdown Modifiers

private struct ScaledContentMarkdownModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.fontPreferenceObserver) private var fontPreferenceObserver
    let baseBodySize: CGFloat
    let baseCodeSize: CGFloat
    let selectionEnabled: Bool

    func body(content: Content) -> some View {
        let scaledBody = baseBodySize * textScale
        let scaledCode = baseCodeSize * textScale
        let _ = syncHighlighterTheme(for: colorScheme)
        let themeKey = MarkdownThemeCache.Key(
            bodySize: scaledBody,
            codeSize: scaledCode,
            isDark: colorScheme == .dark,
            themeVersion: ThemeManager.shared.themeVersion,
            fontRevision: fontPreferenceObserver.revision
        )
        let themed = content
            .markdownTheme(
                MarkdownThemeCache.shared.contentTheme(themeKey) {
                    litterContentTheme(bodySize: scaledBody, codeSize: scaledCode)
                }
            )
            .codeSyntaxHighlighter(sharedHighlighter)
            .codeBlockRenderer(LitterCodeBlockRenderer())
            .id(fontPreferenceObserver.revision)
        if selectionEnabled {
            themed.textSelection(.enabled)
        } else {
            themed
        }
    }
}

private struct ScaledSystemMarkdownModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.fontPreferenceObserver) private var fontPreferenceObserver
    let baseBodySize: CGFloat
    let baseCodeSize: CGFloat
    let selectionEnabled: Bool

    func body(content: Content) -> some View {
        let scaledBody = baseBodySize * textScale
        let scaledCode = baseCodeSize * textScale
        let _ = syncHighlighterTheme(for: colorScheme)
        let themeKey = MarkdownThemeCache.Key(
            bodySize: scaledBody,
            codeSize: scaledCode,
            isDark: colorScheme == .dark,
            themeVersion: ThemeManager.shared.themeVersion,
            fontRevision: fontPreferenceObserver.revision
        )
        let themed = content
            .markdownTheme(
                MarkdownThemeCache.shared.systemTheme(themeKey) {
                    litterSystemTheme(bodySize: scaledBody, codeSize: scaledCode)
                }
            )
            .codeSyntaxHighlighter(sharedHighlighter)
            .codeBlockRenderer(LitterCodeBlockRenderer())
            .id(fontPreferenceObserver.revision)
        if selectionEnabled {
            themed.textSelection(.enabled)
        } else {
            themed
        }
    }
}

extension View {
    func litterContentMarkdown(
        bodySize: CGFloat = LitterFont.conversationBodyPointSize,
        codeSize: CGFloat = LitterFont.conversationBodyPointSize,
        selectionEnabled: Bool = true
    ) -> some View {
        modifier(
            ScaledContentMarkdownModifier(
                baseBodySize: bodySize,
                baseCodeSize: codeSize,
                selectionEnabled: selectionEnabled
            )
        )
    }

    func litterSystemMarkdown(
        bodySize: CGFloat = LitterFont.conversationBodyPointSize,
        codeSize: CGFloat = LitterFont.conversationBodyPointSize,
        selectionEnabled: Bool = true
    ) -> some View {
        modifier(
            ScaledSystemMarkdownModifier(
                baseBodySize: bodySize,
                baseCodeSize: codeSize,
                selectionEnabled: selectionEnabled
            )
        )
    }
}
