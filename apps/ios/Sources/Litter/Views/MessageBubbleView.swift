import SwiftUI
import Hairball
import HairballUI
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

    var body: some View {
        if debugSettings.enabled && debugSettings.disableMarkdown {
            Text(markdown)
                .font(.system(size: bodySize, design: .monospaced))
                .foregroundColor(style == .system ? LitterTheme.textSecondary : LitterTheme.textPrimary)
                .textSelection(.enabled)
        } else {
            renderedMarkdown(selectionEnabled: selectionEnabled)
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
        case .system:
            view.litterSystemMarkdown(
                bodySize: bodySize, codeSize: codeSize,
                selectionEnabled: selectionEnabled
            )
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
                    if let uiImage = UserBubble.decodeImage(img) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 200, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .draggable(Image(uiImage: uiImage)) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 120)
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

    private static let imageCache = NSCache<NSString, UIImage>()

    private var visibleText: String {
        guard shouldLimitText, !expandedLongText else {
            return text
        }
        return String(text.prefix(maxVisibleCharacters))
    }

    private var shouldLimitText: Bool {
        text.count > maxVisibleCharacters
    }

    private static func decodeImage(_ image: ChatImage) -> UIImage? {
        let key = image.cacheKey as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let data = imageData(for: image) else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static func imageData(for image: ChatImage) -> Data? {
        let source = image.source
        guard source.hasPrefix("data:") || source.hasPrefix("file://") else {
            return nil
        }

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
                LitterMarkdownView(
                    markdown: mathBlockMarkdown(code),
                    style: .content,
                    bodySize: contentFontSize,
                    codeSize: contentFontSize
                )
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
        case .image(let uiImage):
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .draggable(Image(uiImage: uiImage)) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120)
                }
        }
    }

    private func isMathCodeBlock(_ language: String?) -> Bool {
        guard let language else { return false }
        return language.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("math") == .orderedSame
    }

    private func mathBlockMarkdown(_ code: String) -> String {
        "```math\n\(code)\n```"
    }
}

struct StreamingAssistantBubble: View {
    @Environment(WallpaperManager.self) private var wallpaperManager
    @Environment(\.activeThreadKey) private var threadKey
    let itemId: String
    let text: String
    var isStreaming: Bool = false
    var label: String? = nil
    var themeVersion: Int = 0
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
        themeVersion: Int = 0,
        bodySize: CGFloat = LitterFont.conversationBodyPointSize,
        onSnapshotRendered: (() -> Void)? = nil
    ) {
        self.itemId = itemId
        self.text = text
        self.isStreaming = isStreaming
        self.label = label
        self.themeVersion = themeVersion
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
        .onChange(of: text) {
            onSnapshotRendered?()
        }
    }
}

// MARK: - Full message bubble (used in conversation)

struct MessageBubbleView: View {
    private let renderCache = MessageRenderCache.shared
    @Environment(\.activeThreadKey) private var activeThreadKey
    let message: ChatMessage
    let serverId: String?
    let originThreadId: String?
    let agentDirectoryVersion: UInt64
    let isStreamingMessage: Bool
    let actionsDisabled: Bool
    let onStreamingSnapshotRendered: (() -> Void)?
    let resolveTargetLabel: ((String) -> String?)?
    let onWidgetPrompt: ((String) -> Void)?
    let onEditUserMessage: ((ChatMessage) -> Void)?
    let onForkFromUserMessage: ((ChatMessage) -> Void)?
    private let contentFontSize = LitterFont.conversationBodyPointSize

    init(
        message: ChatMessage,
        serverId: String? = nil,
        originThreadId: String? = nil,
        agentDirectoryVersion: UInt64 = 0,
        isStreamingMessage: Bool = false,
        actionsDisabled: Bool = false,
        onStreamingSnapshotRendered: (() -> Void)? = nil,
        resolveTargetLabel: ((String) -> String?)? = nil,
        onWidgetPrompt: ((String) -> Void)? = nil,
        onEditUserMessage: ((ChatMessage) -> Void)? = nil,
        onForkFromUserMessage: ((ChatMessage) -> Void)? = nil
    ) {
        self.message = message
        self.serverId = serverId
        self.originThreadId = originThreadId
        self.agentDirectoryVersion = agentDirectoryVersion
        self.isStreamingMessage = isStreamingMessage
        self.actionsDisabled = actionsDisabled
        self.onStreamingSnapshotRendered = onStreamingSnapshotRendered
        self.resolveTargetLabel = resolveTargetLabel
        self.onWidgetPrompt = onWidgetPrompt
        self.onEditUserMessage = onEditUserMessage
        self.onForkFromUserMessage = onForkFromUserMessage
    }

    var body: some View {
        Group {
            if message.role == .user {
                userBubbleWithActions
            } else if message.role == .assistant {
                assistantContent
            } else if isReasoning {
                HStack(alignment: .top, spacing: 0) {
                    reasoningContent
                    Spacer(minLength: 20)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    systemBubble
                    Spacer(minLength: 20)
                }
            }
        }
    }

    private var renderRevisionKey: MessageRenderCache.RevisionKey {
        MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: serverId,
            agentDirectoryVersion: agentDirectoryVersion,
            isStreaming: isStreamingMessage
        )
    }

    private var resolvedOriginThreadId: String? {
        originThreadId ?? activeThreadKey?.threadId
    }

    private var isReasoning: Bool {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return false }
        let firstLine = trimmed.prefix(while: { $0 != "\n" })
        return firstLine.lowercased().contains("reason")
    }

    private var supportsUserActions: Bool {
        message.role == .user &&
            message.isFromUserTurnBoundary &&
            message.sourceTurnIndex != nil
    }

    private var canCopyMessageText: Bool {
        !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var userBubbleWithActions: some View {
        UserBubble(text: message.text, images: message.images)
            .contextMenu {
                if canCopyMessageText {
                    Button("Copy Message") {
                        UIPasteboard.general.string = message.text
                    }
                }

                if supportsUserActions {
                    Button("Edit Message") {
                        onEditUserMessage?(message)
                    }
                    .disabled(actionsDisabled || onEditUserMessage == nil)

                    Button("Fork From Here") {
                        onForkFromUserMessage?(message)
                    }
                    .disabled(actionsDisabled || onForkFromUserMessage == nil)
                }
            }
    }

    @ViewBuilder
    private var assistantContent: some View {
        Group {
            if isStreamingMessage {
                StreamingAssistantBubble(
                    itemId: message.id.uuidString,
                    text: message.text,
                    isStreaming: true,
                    label: assistantAgentLabel,
                    onSnapshotRendered: onStreamingSnapshotRendered
                )
            } else {
                AssistantBlocksBubble(
                    segments: assistantSegmentsForRendering,
                    label: assistantAgentLabel
                )
            }
        }
        .contextMenu {
            if canCopyMessageText {
                Button("Copy Message") {
                    UIPasteboard.general.string = message.text
                }
            }
        }
    }

    private var assistantAgentLabel: String? {
        AgentLabelFormatter.format(
            nickname: message.agentNickname,
            role: message.agentRole
        )
    }

    private var reasoningContent: some View {
        let (_, body) = extractSystemTitleAndBody(message.text)
        return Text(normalizedReasoningText(body))
            .litterFont(size: contentFontSize)
            .italic()
            .foregroundColor(LitterTheme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                if canCopyMessageText {
                    Button("Copy Message") {
                        UIPasteboard.general.string = message.text
                    }
                }
            }
    }

    @ViewBuilder
    private var systemBubble: some View {
        if let widget = message.widgetState {
            WidgetContainerView(
                widget: widget,
                originThreadId: resolvedOriginThreadId,
                onMessage: handleWidgetMessage
            )
        } else {
            let parsed = systemParseResultForRendering
            switch parsed {
            case .recognized(let model):
                ToolCallCardView(model: model, serverId: serverId)
            case .unrecognized:
                genericSystemBubble
            }
        }
    }

    private func handleWidgetMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["_type"] as? String else { return }
        switch type {
        case "sendPrompt":
            if let text = dict["text"] as? String, !text.isEmpty {
                onWidgetPrompt?(text)
            }
        case "openLink":
            if let urlStr = dict["url"] as? String, let url = URL(string: urlStr) {
                UIApplication.shared.open(url)
            }
        default:
            break
        }
    }

    private var genericSystemBubble: some View {
        let (title, body) = extractSystemTitleAndBody(message.text)
        let markdown = title == nil ? message.text : body
        let displayTitle = title ?? "System"

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .litterFont(size: 11, weight: .semibold)
                    .foregroundColor(LitterTheme.accent)
                Text(displayTitle.uppercased())
                    .litterFont(.caption2, weight: .bold)
                    .foregroundColor(LitterTheme.accent)
                Spacer()
            }

            if !markdown.isEmpty {
                LitterMarkdownView(
                    markdown: markdown,
                    style: .system,
                    bodySize: contentFontSize,
                    codeSize: contentFontSize
                )
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(GlassRectModifier(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(LitterTheme.accent.opacity(0.9))
                .frame(width: 3)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if canCopyMessageText {
                Button("Copy Message") {
                    UIPasteboard.general.string = message.text
                }
            }
        }
    }

    private func extractSystemTitleAndBody(_ text: String) -> (String?, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return (nil, trimmed) }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return (nil, trimmed) }
        let title = first.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? nil : title, body)
    }

    private func normalizedReasoningText(_ body: String) -> String {
        body
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 {
                    return String(trimmed.dropFirst(2).dropLast(2))
                }
                return line
            }
            .joined(separator: "\n")
    }

    private var assistantSegmentsForRendering: [MessageRenderCache.AssistantSegment] {
        renderCache.assistantSegments(
            for: message,
            key: renderRevisionKey
        )
    }

    private var systemParseResultForRendering: ToolCallParseResult {
        renderCache.systemParseResult(
            for: message,
            key: renderRevisionKey,
            resolveTargetLabel: resolveTargetLabel
        )
    }
}

// MARK: - Litter Markdown Themes

private func litterContentTheme(bodySize: CGFloat, codeSize: CGFloat) -> MarkdownTheme {
    var theme = MarkdownTheme.default
    theme.bodyFont = .custom(LitterFont.markdownFontName, size: bodySize)
    theme.bodyFontSize = bodySize
    theme.foregroundColor = LitterTheme.textBody
    theme.paragraphSpacing = 8
    theme.blockSpacing = 8

    theme.headingStyleSet = HeadingStyleSet(
        h1: HeadingStyle(fontSize: bodySize * 1.43, weight: .bold,
                         topSpacing: 16, bottomSpacing: 8, color: LitterTheme.textPrimary),
        h2: HeadingStyle(fontSize: bodySize * 1.21, weight: .semibold,
                         topSpacing: 12, bottomSpacing: 6, color: LitterTheme.textPrimary),
        h3: HeadingStyle(fontSize: bodySize * 1.07, weight: .semibold,
                         topSpacing: 10, bottomSpacing: 4, color: LitterTheme.textPrimary),
        h4: HeadingStyle(fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary),
        h5: HeadingStyle(fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary),
        h6: HeadingStyle(fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary)
    )

    theme.inlineCode = InlineCodeStyle(
        backgroundColor: LitterTheme.surfaceLight,
        textColor: LitterTheme.textPrimary,
        font: .custom(LitterFont.markdownFontName, size: codeSize),
        fontSize: codeSize
    )

    theme.codeBlock = CodeBlockStyle(
        backgroundColor: LitterTheme.codeBackground.opacity(0.8),
        textColor: LitterTheme.textPrimary,
        font: .custom(LitterFont.markdownFontName, size: codeSize),
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
    theme.bodyFont = .custom(LitterFont.markdownFontName, size: bodySize)
    theme.bodyFontSize = bodySize
    theme.foregroundColor = LitterTheme.textSystem
    theme.paragraphSpacing = 6
    theme.blockSpacing = 6

    theme.headingStyleSet = HeadingStyleSet(
        h1: HeadingStyle(fontSize: bodySize * 1.31, weight: .bold,
                         topSpacing: 12, bottomSpacing: 6, color: LitterTheme.textPrimary),
        h2: HeadingStyle(fontSize: bodySize * 1.15, weight: .semibold,
                         topSpacing: 10, bottomSpacing: 4, color: LitterTheme.textPrimary),
        h3: HeadingStyle(fontSize: bodySize * 1.08, weight: .semibold,
                         topSpacing: 8, bottomSpacing: 4, color: LitterTheme.textPrimary),
        h4: HeadingStyle(fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary),
        h5: HeadingStyle(fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary),
        h6: HeadingStyle(fontSize: bodySize, weight: .semibold, color: LitterTheme.textPrimary)
    )

    theme.inlineCode = InlineCodeStyle(
        backgroundColor: LitterTheme.surfaceLight,
        textColor: LitterTheme.textPrimary,
        font: .custom(LitterFont.markdownFontName, size: codeSize),
        fontSize: codeSize
    )

    theme.codeBlock = CodeBlockStyle(
        backgroundColor: LitterTheme.codeBackground.opacity(0.8),
        textColor: LitterTheme.textPrimary,
        font: .custom(LitterFont.markdownFontName, size: codeSize),
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
        } else {
            DefaultCodeBlockRenderer().makeBody(configuration: configuration)
                .modifier(GlassRectModifier(cornerRadius: 8))
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
    @AppStorage("fontFamily") private var fontFamily = FontFamilyOption.mono.rawValue
    let baseBodySize: CGFloat
    let baseCodeSize: CGFloat
    let selectionEnabled: Bool

    func body(content: Content) -> some View {
        let _ = fontFamily
        let scaledBody = baseBodySize * textScale
        let scaledCode = baseCodeSize * textScale
        let _ = syncHighlighterTheme(for: colorScheme)
        let themed = content
            .markdownTheme(litterContentTheme(bodySize: scaledBody, codeSize: scaledCode))
            .codeSyntaxHighlighter(sharedHighlighter)
            .codeBlockRenderer(LitterCodeBlockRenderer())
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
    @AppStorage("fontFamily") private var fontFamily = FontFamilyOption.mono.rawValue
    let baseBodySize: CGFloat
    let baseCodeSize: CGFloat
    let selectionEnabled: Bool

    func body(content: Content) -> some View {
        let _ = fontFamily
        let scaledBody = baseBodySize * textScale
        let scaledCode = baseCodeSize * textScale
        let _ = syncHighlighterTheme(for: colorScheme)
        let themed = content
            .markdownTheme(litterSystemTheme(bodySize: scaledBody, codeSize: scaledCode))
            .codeSyntaxHighlighter(sharedHighlighter)
            .codeBlockRenderer(LitterCodeBlockRenderer())
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

#if DEBUG
#Preview("Message Bubbles") {
    LitterPreviewScene {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(LitterPreviewData.sampleMessages) { message in
                    MessageBubbleView(
                        message: message,
                        serverId: LitterPreviewData.sampleServer.id
                    )
                }
            }
            .padding(16)
        }
    }
}
#endif
