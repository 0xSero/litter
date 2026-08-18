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

    @Environment(\.fontPreferenceObserver) private var fontPreferenceObserver

    var body: some View {
        if DebugSettings.isMarkdownDisabled {
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
        ExternalBrowserURLHandler.action
    }
}

/// Shared open-URL handler that opens http(s) links in the external browser
/// (Safari) and defers everything else to the system. Used by both
/// `LitterMarkdownView` and `AssistantBlocksBubble` so links are tappable
/// regardless of which rendering path the message takes.
enum ExternalBrowserURLHandler {
    static let action: OpenURLAction = OpenURLAction { url in
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .systemAction
        }
        UIApplication.shared.open(url)
        return .handled
    }
}

struct InlineSelectableMarkdownMessage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

struct UserBubble: View, Equatable {
    let text: String
    var images: [ChatImage] = []
    var compact: Bool = false
    var maxVisibleCharacters: Int = 1_000
    @State private var expandedLongText = false

    static func == (lhs: UserBubble, rhs: UserBubble) -> Bool {
        lhs.text == rhs.text &&
        lhs.images == rhs.images &&
        lhs.compact == rhs.compact &&
        lhs.maxVisibleCharacters == rhs.maxVisibleCharacters
    }
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
        guard source.hasPrefix("data:") || source.hasPrefix("file://") || source.hasPrefix("http://") || source.hasPrefix("https://") else {
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

        // Remote URLs: let Nuke handle the network fetch via its default
        // URLSession pipeline rather than blocking on a synchronous data
        // provider closure.
        if source.hasPrefix("http://") || source.hasPrefix("https://"),
           let url = URL(string: source) {
            return ImageRequest(
                url: url,
                processors: processors
            )
        }

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
    var themeVersion: Int = 0
    var allowsInlineSelection: Bool = true
    private let contentFontSize = LitterFont.conversationBodyPointSize

    init(
        text: String,
        label: String? = nil,
        compact: Bool = false,
        themeVersion: Int = 0,
        allowsInlineSelection: Bool = true
    ) {
        self.markdownString = text
        self.markdownIdentity = text.hashValue
        self.label = label
        self.compact = compact
        self.themeVersion = themeVersion
        self.allowsInlineSelection = allowsInlineSelection
    }

    init(
        markdownString: String,
        markdownIdentity: Int,
        label: String? = nil,
        compact: Bool = false,
        themeVersion: Int = 0,
        allowsInlineSelection: Bool = true
    ) {
        self.markdownString = markdownString
        self.markdownIdentity = markdownIdentity
        self.label = label
        self.compact = compact
        self.themeVersion = themeVersion
        self.allowsInlineSelection = allowsInlineSelection
    }

    static func == (lhs: AssistantBubble, rhs: AssistantBubble) -> Bool {
        lhs.markdownIdentity == rhs.markdownIdentity &&
        lhs.label == rhs.label &&
        lhs.compact == rhs.compact &&
        lhs.themeVersion == rhs.themeVersion &&
        lhs.allowsInlineSelection == rhs.allowsInlineSelection
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if allowsInlineSelection {
                InlineSelectableMarkdownMessage {
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
        .modifier(MessageTextContextMenu(payload: .text(markdownString)))
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
            .modifier(MessageTextContextMenu(payload: .segments(segments)))
            .environment(\.openURL, ExternalBrowserURLHandler.action)
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
        !isStreaming || StreamingAssistantRenderCache.shared.containsMath(itemId: itemId, text: text)
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

// MARK: - Litter Markdown Themes

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
                        titleHint: configuration.language,
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

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                UIPasteboard.general.string = code
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if AppModel.shared.store.activeTerminalId() != nil {
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
    }
}

// MARK: - Message Text Selection / Copy

/// What a message context menu should put on the pasteboard.
///
/// Held as an enum rather than a pre-joined `String` so that assistant messages
/// rendered as segments do not pay a join on every body evaluation — the text is
/// only materialized inside the menu action, which runs on tap.
private enum MessageCopyPayload {
    case text(String)
    case segments([MessageRenderCache.AssistantSegment])

    var plainText: String {
        switch self {
        case .text(let value):
            return value
        case .segments(let segments):
            var parts: [String] = []
            parts.reserveCapacity(segments.count)
            for segment in segments {
                switch segment.kind {
                case .markdown(let content, _):
                    parts.append(content)
                case .codeBlock(let language, let code, _):
                    let fence = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    parts.append("```\(fence)\n\(code)\n```")
                case .image, .localImage:
                    continue
                }
            }
            return parts.joined(separator: "\n\n")
        }
    }
}

/// Adds a long-press "Copy" / "Select Text" menu to a chat message.
///
/// Mirrors `CodeBlockTerminalContextMenu`, and is deliberately cheap on the
/// render path:
/// * the `contextMenu` builder is only evaluated when the menu opens, so the
///   trim/join work never runs during scrolling or streaming;
/// * it stores a payload rather than a closure, so no per-body-eval allocation;
/// * "Select Text" presents imperatively through the window scene instead of a
///   `.sheet` modifier — one presentation modifier per transcript row would cost
///   real memory and layout work on long threads.
///
/// Fine-grained in-place selection still comes from `.textSelection(.enabled)`
/// applied by the markdown modifiers; this menu guarantees a whole-message copy
/// and a selectable full-text view even where the renderer swallows the drag.
private struct MessageTextContextMenu: ViewModifier {
    let payload: MessageCopyPayload

    func body(content: Content) -> some View {
        content.contextMenu {
            let text = payload.plainText
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    MessageTextSelectionPresenter.present(text: text)
                } label: {
                    Label("Select Text", systemImage: "character.cursor.ibeam")
                }
            }
        }
    }
}

/// Presents `MessageTextSelectionView` without attaching a `.sheet` modifier to
/// every transcript row.
@MainActor
private enum MessageTextSelectionPresenter {
    private final class HostBox {
        weak var controller: UIViewController?
    }

    static func present(text: String) {
        guard let presenter = topViewController() else { return }
        let box = HostBox()
        let host = UIHostingController(
            rootView: MessageTextSelectionView(text: text) { [box] in
                box.controller?.dismiss(animated: true)
            }
        )
        box.controller = host
        host.modalPresentationStyle = .pageSheet
        presenter.present(host, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

/// Plain-text view of a message whose body is fully selectable, so a reader can
/// drag out an arbitrary range instead of copying the whole message.
private struct MessageTextSelectionView: View {
    let text: String
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .litterFont(size: LitterFont.conversationBodyPointSize)
                    .foregroundColor(LitterTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(LitterTheme.surface.ignoresSafeArea())
            .navigationTitle("Select Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}

// MARK: - Syntax Highlighting Theme Mapping

/// Shared highlighter instance — theme is switched at runtime via `setTheme(_:)`.
private let sharedHighlighter = HighlightrCodeSyntaxHighlighter(theme: "atom-one-dark")

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
        let themed = content
            .markdownTheme(litterContentTheme(bodySize: scaledBody, codeSize: scaledCode))
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
        let themed = content
            .markdownTheme(litterSystemTheme(bodySize: scaledBody, codeSize: scaledCode))
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
