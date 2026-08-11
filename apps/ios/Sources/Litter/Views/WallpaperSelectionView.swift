import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Hairball
import HairballUI

private struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let destURL = tempDir.appendingPathComponent(UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: received.file, to: destURL)
            return Self(url: destURL)
        }
    }
}

struct WallpaperSelectionView: View {
    @Environment(WallpaperManager.self) private var wallpaperManager
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    let threadKey: ThreadKey?
    var serverId: String? = nil
    var onSelectWallpaper: ((WallpaperConfig, UIImage?) -> Void)?
    var onClose: (() -> Void)?

    private var resolvedServerId: String? {
        threadKey?.serverId ?? serverId
    }

    @State private var selectedThemeSlug: String?
    @State private var selectedColor: Color?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var customImage: UIImage?
    @State private var previewConfig: WallpaperConfig?
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var isProcessingVideo = false
    @State private var videoURLText: String = ""
    @State private var videoFileURL: URL?
    @State private var videoErrorMessage: String?
    @State private var activeTab: WallpaperTab = .background
    @State private var typingEffectConfig: TypingEffectConfig = .default
    @State private var sheetOffset: CGFloat = 0
    @GestureState private var dragOffset: CGFloat = 0

    private var typingEffectScope: WallpaperScope? {
        if let threadKey { return .thread(threadKey) }
        if let resolvedServerId { return .server(resolvedServerId) }
        return nil
    }

    var body: some View {
        ZStack {
            // Sample bubbles overlay
            sampleBubbles
                .padding(.top, 80)
                .padding(.bottom, max(300 - sheetOffset - dragOffset, 80))

            // Bottom card
            VStack {
                Spacer()
                bottomCard
            }
            .offset(y: max(sheetOffset + dragOffset, 0))
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                            let projected = value.predictedEndTranslation.height
                            if projected > 120 {
                                // Snap down (collapsed)
                                sheetOffset = 280
                            } else if projected < -80 {
                                // Snap up (expanded)
                                sheetOffset = 0
                            } else {
                                // Stay at nearest snap point
                                sheetOffset = sheetOffset + value.translation.height > 140 ? 280 : 0
                            }
                        }
                    }
            )

            // Close button (top-left)
            VStack {
                HStack {
                    Button {
                        onClose?()
                    } label: {
                        Text("Close")
                            .litterFont(size: 15, weight: .medium)
                            .foregroundStyle(LitterTheme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .modifier(GlassRectModifier(cornerRadius: 10))
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .background {
            wallpaperPreview
                .ignoresSafeArea()
        }
        .navigationBarBackButtonHidden(true)
        .alert("Video Error", isPresented: Binding(
            get: { videoErrorMessage != nil },
            set: { if !$0 { videoErrorMessage = nil } }
        )) {
            Button("OK") { videoErrorMessage = nil }
        } message: {
            Text(videoErrorMessage ?? "")
        }
        .onAppear {
            if let threadKey {
                typingEffectConfig = wallpaperManager.resolveTypingEffect(for: threadKey)
            } else if let resolvedServerId {
                typingEffectConfig = wallpaperManager.resolveTypingEffectForServer(resolvedServerId)
            }
        }
    }

    // MARK: - Preview Background

    @ViewBuilder
    private var wallpaperPreview: some View {
        if let config = previewConfig {
            switch config.type {
            case .theme:
                if let slug = config.themeSlug,
                   let image = wallpaperManager.generateWallpaper(themeSlug: slug, themeManager: themeManager) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LitterTheme.backgroundGradient
                }
            case .solidColor:
                if let hex = config.colorHex {
                    Color(hex: hex)
                } else {
                    LitterTheme.backgroundGradient
                }
            case .customImage:
                if let customImage {
                    Image(uiImage: customImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LitterTheme.backgroundGradient
                }
            case .customVideo, .videoUrl:
                if let videoFileURL, FileManager.default.fileExists(atPath: videoFileURL.path) {
                    VideoWallpaperPlayerView(fileURL: videoFileURL)
                } else {
                    LitterTheme.backgroundGradient
                }
            case .none:
                LitterTheme.backgroundGradient
            }
        } else {
            ChatWallpaperBackground(threadKey: threadKey)
        }
    }

    // MARK: - Sample Bubbles

    private var sampleBubbles: some View {
        VStack(spacing: 12) {
            Spacer()
            // User bubble
            HStack {
                Spacer()
                Text("Fix the login bug on the profile page")
                    .litterFont(size: 14)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .modifier(GlassRectModifier(cornerRadius: 14, tint: LitterTheme.accent.opacity(0.3)))
            }
            .padding(.horizontal, 16)

            // Streaming assistant bubble
            HStack {
                StreamingEffectPreview(config: typingEffectConfig)
                    .id(typingEffectConfig)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .modifier(GlassRectModifier(cornerRadius: 14))
                Spacer()
            }
            .padding(.horizontal, 16)

            Spacer()
        }
    }

    // MARK: - Bottom Card

    private var bottomCard: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 2)
                .fill(LitterTheme.textMuted.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Tab picker
            Picker("", selection: $activeTab) {
                ForEach(WallpaperTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Tab content
            switch activeTab {
            case .background:
                backgroundTabContent
            case .typingEffect:
                typingEffectTabContent
            }
        }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(LitterTheme.surface.opacity(0.95))
        )
    }

    private var backgroundTabContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // Theme thumbnails
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        noWallpaperThumbnail
                        ForEach(themeManager.themeIndex) { entry in
                            themeThumbnail(for: entry)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Divider().overlay(LitterTheme.separator)

                // Photos picker
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 16))
                            .foregroundStyle(LitterTheme.accent)
                        Text("Choose Wallpaper from Photos")
                            .litterFont(size: 14)
                            .foregroundStyle(LitterTheme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(LitterTheme.textMuted)
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: selectedPhoto) { _, newItem in
                    Task { await loadPhoto(newItem) }
                }

                // Video picker
                PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                    HStack(spacing: 10) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(LitterTheme.accent)
                        Text("Choose Video from Photos")
                            .litterFont(size: 14)
                            .foregroundStyle(LitterTheme.textPrimary)
                        Spacer()
                        if isProcessingVideo {
                            ProgressView()
                                .tint(LitterTheme.accent)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(LitterTheme.textMuted)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .disabled(isProcessingVideo)
                .onChange(of: selectedVideoItem) { _, newItem in
                    Task { await loadVideo(newItem) }
                }

                // Video URL input
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.system(size: 16))
                        .foregroundStyle(LitterTheme.accent)
                    TextField("Paste video URL", text: $videoURLText)
                        .litterFont(size: 14)
                        .foregroundStyle(LitterTheme.textPrimary)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit { Task { await loadVideoFromURL() } }
                    if !videoURLText.isEmpty {
                        Button {
                            Task { await loadVideoFromURL() }
                        } label: {
                            Text("Go")
                                .litterFont(size: 13, weight: .semibold)
                                .foregroundStyle(LitterTheme.accent)
                        }
                        .disabled(isProcessingVideo)
                    }
                }
                .padding(.horizontal, 16)

                // Color picker
                colorRow

                Spacer().frame(height: 16)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var typingEffectTabContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            typingEffectSection
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Thumbnails

    private var noWallpaperThumbnail: some View {
        Button {
            previewConfig = WallpaperConfig(type: .none)
            selectedThemeSlug = nil
            selectedColor = nil
            customImage = nil
            // Apply immediately
            if let threadKey {
                wallpaperManager.setWallpaper(WallpaperConfig(type: .none), scope: .thread(threadKey))
            } else if let resolvedServerId {
                wallpaperManager.setWallpaper(WallpaperConfig(type: .none), scope: .server(resolvedServerId))
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LitterTheme.surface)
                        .frame(width: 68, height: 100)
                    Image(systemName: "xmark")
                        .font(.system(size: 18))
                        .foregroundStyle(LitterTheme.textMuted)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selectedThemeSlug == nil && previewConfig?.type == WallpaperType.none ? LitterTheme.accent : LitterTheme.border, lineWidth: 2)
                )

                Text("None")
                    .litterFont(size: 10)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func themeThumbnail(for entry: ThemeIndexEntry) -> some View {
        Button {
            selectedThemeSlug = entry.slug
            selectedColor = nil
            customImage = nil
            let config = WallpaperConfig(type: .theme, themeSlug: entry.slug)
            previewConfig = config
            onSelectWallpaper?(config, nil)
        } label: {
            VStack(spacing: 6) {
                Image(uiImage: wallpaperManager.generateThumbnail(for: entry))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 68, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedThemeSlug == entry.slug ? LitterTheme.accent : LitterTheme.border, lineWidth: 2)
                    )

                Text(entry.name)
                    .litterFont(size: 10)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 68)
            }
        }
    }

    // MARK: - Color Picker

    private var colorRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "paintpalette")
                .font(.system(size: 16))
                .foregroundStyle(LitterTheme.accent)
            Text("Set a Color")
                .litterFont(size: 14)
                .foregroundStyle(LitterTheme.textPrimary)
            Spacer()

            ColorPicker("", selection: Binding(
                get: { selectedColor ?? .black },
                set: { color in
                    selectedColor = color
                    selectedThemeSlug = nil
                    customImage = nil
                    let hex = colorToHex(color)
                    let config = WallpaperConfig(type: .solidColor, colorHex: hex)
                    previewConfig = config
                    onSelectWallpaper?(config, nil)
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 30, height: 30)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Typing Effect

    private var selectedGranularity: GranularityKind {
        GranularityKind(rawValue: typingEffectConfig.granularity) ?? .block
    }

    private var selectedEffect: StreamingEffectKind? {
        typingEffectConfig.effects.first.flatMap { StreamingEffectKind(rawValue: $0) }
    }

    private func selectEffect(_ kind: StreamingEffectKind?) {
        typingEffectConfig.effects = kind.map { [$0.rawValue] } ?? []
        persistTypingEffect()
    }

    private func persistTypingEffect() {
        if let scope = typingEffectScope {
            wallpaperManager.setTypingEffect(typingEffectConfig, scope: scope)
        }
    }

    private var typingEffectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Typing Effect")
                .litterFont(size: 16, weight: .semibold)
                .foregroundStyle(LitterTheme.textPrimary)
                .padding(.horizontal, 16)

            // Effect picker
            HStack {
                Text("Effect")
                    .litterFont(size: 13, weight: .medium)
                    .foregroundStyle(LitterTheme.textSecondary)
                Spacer()
                Picker("Effect", selection: Binding(
                    get: { selectedEffect?.rawValue ?? "" },
                    set: { newValue in
                        if newValue.isEmpty {
                            selectEffect(nil)
                        } else if let kind = StreamingEffectKind(rawValue: newValue) {
                            selectEffect(kind)
                        }
                    }
                )) {
                    Text("None").tag("")
                    ForEach(StreamingEffectKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(LitterTheme.accent)
            }
            .padding(.horizontal, 16)

            // Speed slider
            VStack(alignment: .leading, spacing: 6) {
                Text("Reveal Speed")
                    .litterFont(size: 13, weight: .medium)
                    .foregroundStyle(LitterTheme.textSecondary)

                HStack(spacing: 10) {
                    Image(systemName: "hare")
                        .font(.system(size: 11))
                        .foregroundStyle(LitterTheme.textMuted)

                    Slider(
                        value: Binding(
                            get: { typingEffectConfig.revealDuration },
                            set: {
                                typingEffectConfig.revealDuration = $0
                                persistTypingEffect()
                            }
                        ),
                        in: 0.03...1.2,
                        step: 0.01
                    )
                    .tint(LitterTheme.accent)

                    Image(systemName: "tortoise")
                        .font(.system(size: 11))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .padding(.horizontal, 16)

            // Granularity
            HStack(spacing: 0) {
                ForEach(GranularityKind.allCases) { kind in
                    Button {
                        typingEffectConfig.granularity = kind.rawValue
                        persistTypingEffect()
                    } label: {
                        Text(kind.shortLabel)
                            .litterFont(size: 12, weight: selectedGranularity == kind ? .semibold : .regular)
                            .foregroundStyle(selectedGranularity == kind ? LitterTheme.textOnAccent : LitterTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(selectedGranularity == kind ? LitterTheme.accent : .clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(LitterTheme.surfaceLight.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(LitterTheme.border.opacity(0.6), lineWidth: 1))
            .padding(.horizontal, 16)

            // Reveal mode
            HStack(spacing: 0) {
                ForEach(["Linear", "Continuous"], id: \.self) { mode in
                    Button {
                        typingEffectConfig.revealMode = mode
                        persistTypingEffect()
                    } label: {
                        Text(mode)
                            .litterFont(size: 12, weight: typingEffectConfig.revealMode == mode ? .semibold : .regular)
                            .foregroundStyle(typingEffectConfig.revealMode == mode ? LitterTheme.textOnAccent : LitterTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(typingEffectConfig.revealMode == mode ? LitterTheme.accent : .clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(LitterTheme.surfaceLight.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(LitterTheme.border.opacity(0.6), lineWidth: 1))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Helpers

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        await MainActor.run {
            customImage = image
            selectedThemeSlug = nil
            selectedColor = nil
            let config = WallpaperConfig(type: .customImage)
            previewConfig = config
            if let threadKey {
                wallpaperManager.setCustomImage(image, scope: .thread(threadKey))
            } else if let resolvedServerId {
                wallpaperManager.setCustomImage(image, scope: .server(resolvedServerId))
            }
            onSelectWallpaper?(config, image)
        }
    }

    private func loadVideo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        await MainActor.run { isProcessingVideo = true }
        defer { Task { @MainActor in isProcessingVideo = false } }

        // Load the video data as a transferable file URL
        guard let movie = try? await item.loadTransferable(type: VideoTransferable.self) else {
            LLog.error("wallpaper", "failed to load video from picker")
            return
        }

        let scope: WallpaperScope
        if let threadKey {
            scope = .thread(threadKey)
        } else if let resolvedServerId {
            scope = .server(resolvedServerId)
        } else {
            return
        }
        let destURL = wallpaperManager.videoFileURL(for: scope)

        do {
            let duration = try await VideoWallpaperProcessor.transcode(source: movie.url, destination: destURL)
            await MainActor.run {
                var config = WallpaperConfig(type: .customVideo)
                config.videoDuration = duration
                previewConfig = config
                videoFileURL = destURL
                selectedThemeSlug = nil
                selectedColor = nil
                customImage = nil
                wallpaperManager.setWallpaper(config, scope: scope)
                onSelectWallpaper?(config, nil)
            }
        } catch {
            LLog.error("wallpaper", "video transcode failed", error: error)
            await MainActor.run { videoErrorMessage = error.localizedDescription }
        }
    }

    private func loadVideoFromURL() async {
        let trimmed = videoURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remoteURL = URL(string: trimmed), remoteURL.scheme == "http" || remoteURL.scheme == "https" else {
            return
        }

        await MainActor.run { isProcessingVideo = true }
        defer { Task { @MainActor in isProcessingVideo = false } }

        let scope: WallpaperScope
        if let threadKey {
            scope = .thread(threadKey)
        } else if let resolvedServerId {
            scope = .server(resolvedServerId)
        } else {
            return
        }
        let destURL = wallpaperManager.videoFileURL(for: scope)

        do {
            let duration = try await VideoWallpaperProcessor.downloadAndTranscode(remoteURL: remoteURL, destination: destURL)
            await MainActor.run {
                var config = WallpaperConfig(type: .videoUrl, videoURL: trimmed)
                config.videoDuration = duration
                previewConfig = config
                videoFileURL = destURL
                selectedThemeSlug = nil
                selectedColor = nil
                customImage = nil
                videoURLText = ""
                wallpaperManager.setWallpaper(config, scope: scope)
                onSelectWallpaper?(config, nil)
            }
        } catch {
            LLog.error("wallpaper", "video URL download/transcode failed", error: error)
            await MainActor.run { videoErrorMessage = error.localizedDescription }
        }
    }

    private func colorToHex(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Tab Enum

private enum WallpaperTab: String, CaseIterable, Identifiable {
    case background
    case typingEffect

    var id: String { rawValue }

    var label: String {
        switch self {
        case .background: "Background"
        case .typingEffect: "Typing Effect"
        }
    }
}

// MARK: - Streaming Effect Preview

private struct StreamingEffectPreview: View {
    var config: TypingEffectConfig
    @State private var renderer: StreamingMarkdownRenderer
    @State private var feedTask: Task<Void, Never>?

    private static let sampleText = """
    Found the issue — the `SessionManager` was **dropping the refresh token** on every cold start because `loadCredentials()` ran before the keychain unlock callback.

    I moved the credential load into the `didBecomeActive` handler and added a retry with exponential backoff:

    ```swift
    func restoreSession() async throws {
        let creds = try await keychain.load(.session)
        try await client.resume(with: creds)
    }
    ```

    This also fixes the **"phantom logout"** bug users reported on iOS 18. The token was valid but got discarded before the refresh exchange could complete.
    """

    init(config: TypingEffectConfig) {
        self.config = config
        self._renderer = State(initialValue: StreamingMarkdownRenderer(
            processors: [LatexTransformer()],
            throttleInterval: 0.016
        ))
    }

    var body: some View {
        StreamingMarkdownContentView(renderer: renderer)
            .tokenReveal(TokenRevealConfig(
                duration: max(config.revealDuration, 0.01),
                mode: config.effectiveRevealMode
            ))
            .applyStreamingEffect(config.resolvedEffect)
            .revealGranularity(config.effectiveGranularity)
            .litterContentMarkdown(
                bodySize: 14,
                codeSize: 14,
                selectionEnabled: false
            )
            .onAppear { startFeed() }
            .onDisappear { feedTask?.cancel() }
    }

    private func startFeed() {
        let text = Self.sampleText
        feedTask = Task {
            while !Task.isCancelled {
                renderer.reset()
                // Simulate realistic token arrival: 3-8 chars per chunk
                // with variable inter-token delays.
                var index = text.startIndex
                while index < text.endIndex && !Task.isCancelled {
                    let chunkSize = Int.random(in: 3...8)
                    let batchEnd = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                    let chunk = String(text[index..<batchEnd])
                    await MainActor.run { renderer.append(chunk) }
                    index = batchEnd
                    let delay = Int.random(in: 20...60)
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                await MainActor.run { renderer.finish() }
                try? await Task.sleep(for: .seconds(1.0))
            }
        }
    }
}
