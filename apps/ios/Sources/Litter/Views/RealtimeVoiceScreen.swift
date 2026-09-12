import SwiftUI

struct RealtimeVoiceScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var appModel
    @Environment(VoiceRuntimeController.self) private var voiceRuntime
    let threadKey: ThreadKey
    let onEnd: () -> Void
    let onToggleSpeaker: () -> Void

    @State private var apiKey = ""
    @State private var isSavingApiKey = false
    @State private var hasCheckedAuth = false
    @State private var hasStoredApiKey = OpenAIApiKeyStore.shared.hasStoredKey
    @State private var apiKeyError: String?
    @State private var isRetryingAfterAuthSave = false
    /// Snapshot projections mirrored by `snapshotObserver` so `body` never
    /// reads `appModel.snapshot`. A live voice session bumps the snapshot
    /// continuously, and this screen's body is expensive (edge glow +
    /// waveform + transcript).
    @State private var resolvedServer: AppServerSnapshot?
    @State private var handoffThread: AppThreadSnapshot?
    @State private var snapshotObserver = AppSnapshotObserver()

    private var glowPalette: GlowPalette {
        .from(colorScheme: colorScheme)
    }

    private var primaryTextColor: Color {
        LitterTheme.textPrimary
    }

    private var secondaryTextColor: Color {
        LitterTheme.textSecondary
    }

    private var promptFillColor: Color {
        LitterTheme.surface.opacity(colorScheme == .dark ? 0.82 : 0.92)
    }

    private var promptStrokeColor: Color {
        LitterTheme.border.opacity(colorScheme == .dark ? 0.55 : 0.8)
    }

    private var controlFillColor: Color {
        LitterTheme.surfaceLight.opacity(colorScheme == .dark ? 0.72 : 0.88)
    }
    private var session: VoiceSessionState? {
        guard let session = voiceRuntime.activeVoiceSession,
              session.threadKey == threadKey else { return nil }
        return session
    }

    private var server: AppServerSnapshot? {
        resolvedServer
    }

    /// Called from `snapshotObserver`, never from `body`. Writes `@State`
    /// only when a projection actually changed. Takes the model explicitly so
    /// the deferred closure never reads `@Environment`.
    private func refreshSnapshotProjections(_ appModel: AppModel) {
        let snapshot = appModel.snapshot
        let nextServer = snapshot?.serverSnapshot(for: threadKey.serverId)
        if resolvedServer != nextServer {
            resolvedServer = nextServer
        }
        let nextHandoffThread = handoffThreadKey.flatMap { snapshot?.threadSnapshot(for: $0) }
        if handoffThread != nextHandoffThread {
            handoffThread = nextHandoffThread
        }
    }

    private var phase: VoiceSessionPhase {
        session?.phase ?? .connecting
    }

    private var handoffThreadKey: ThreadKey? {
        session?.handoffRemoteThreadKey
    }

    private var inputLevel: CGFloat {
        CGFloat(session?.scaledInputLevel ?? 0)
    }

    private var outputLevel: CGFloat {
        CGFloat(session?.scaledOutputLevel ?? 0)
    }

    private var glowIntensity: CGFloat {
        switch phase {
        case .listening:
            return max(0.3, inputLevel)
        case .speaking:
            return max(0.3, outputLevel)
        case .thinking, .handoff:
            return 0.4
        case .connecting:
            return 0.25
        case .error:
            return 0.1
        }
    }

    private var transcriptHistory: [VoiceSessionTranscriptEntry] {
        session.map {
            $0.transcriptHistory.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        } ?? []
    }

    private var visibleTranscriptEntries: [VoiceSessionTranscriptEntry] {
        var entries = transcriptHistory
        guard let session else { return entries }

        let liveText = session.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !liveText.isEmpty else { return entries }

        let speaker = session.transcriptSpeaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? session.transcriptSpeaker!
            : (session.phase == .speaking ? "Codex" : "You")
        let liveId = session.transcriptLiveMessageID ?? "live-\(speaker.lowercased())"
        let timestamp = entries.first(where: { $0.id == liveId })?.timestamp ?? Date()
        let entry = VoiceSessionTranscriptEntry(
            id: liveId,
            speaker: speaker,
            text: liveText,
            timestamp: timestamp
        )

        if let existingIndex = entries.firstIndex(where: { $0.id == liveId }) {
            entries[existingIndex] = entry
        } else {
            entries.append(entry)
        }
        return entries
    }

    private var transcriptScrollSignature: String? {
        guard let last = visibleTranscriptEntries.last else { return nil }
        return "\(last.id):\(last.text.count)"
    }

    private var shouldShowApiKeyPrompt: Bool {
        guard hasCheckedAuth,
              let server,
              server.isLocal,
              phase == .connecting,
              !hasStoredApiKey else {
            return false
        }
        return true
    }

    private var trimmedApiKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Color(hex: glowPalette.background)
                .ignoresSafeArea()

            SiriEdgeGlow(
                intensity: glowIntensity,
                phase: phase,
                palette: glowPalette
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                transcriptContent
                    .padding(.horizontal, 32)

                if handoffThreadKey != nil {
                    InlineHandoffView(
                        thread: handoffThread,
                        maxHeight: 220
                    )
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .transition(.opacity)
                }

                Spacer()

                bottomControls
                    .padding(.bottom, 40)
            }

            if shouldShowApiKeyPrompt {
                realtimeApiKeyPrompt
                    .padding(.horizontal, 20)
            }
        }
        .statusBarHidden()
        .task {
            // Mirrors the server record and the live handoff thread out of the
            // snapshot on every (coalesced) revision, from a non-body context.
            let model = appModel
            snapshotObserver.start(appModel: model) { refreshSnapshotProjections(model) }
            do {
                _ = try await appModel.client.refreshAccount(
                    serverId: threadKey.serverId,
                    params: AppRefreshAccountRequest(refreshToken: false)
                )
                await appModel.refreshSnapshot()
                await MainActor.run {
                    hasCheckedAuth = true
                    hasStoredApiKey = OpenAIApiKeyStore.shared.hasStoredKey
                    apiKeyError = nil
                }
            } catch {
                await MainActor.run {
                    hasCheckedAuth = true
                    hasStoredApiKey = OpenAIApiKeyStore.shared.hasStoredKey
                    apiKeyError = error.localizedDescription
                }
            }
        }
        .onDisappear { snapshotObserver.stop() }
        // The handoff key comes from `voiceRuntime`, not the snapshot, so a
        // handoff starting/ending needs its own resolve trigger.
        .onChange(of: handoffThreadKey) { _, _ in
            refreshSnapshotProjections(appModel)
        }
        .onChange(of: session?.id) { _, next in
            if next == nil, !isRetryingAfterAuthSave {
                onEnd()
            } else if next != nil {
                isRetryingAfterAuthSave = false
            }
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                VoiceScreenPulsingDot(
                    color: phaseColor,
                    isActive: phase == .listening || phase == .speaking
                )

                Text(phase.displayTitle.uppercased())
                    .font(LitterFont.monospaced(.caption, weight: .bold))
                    .foregroundColor(phaseColor)
                    .tracking(2)
            }

            if phase == .error,
               let error = session?.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
               !error.isEmpty {
                Text(error)
                    .font(LitterFont.styled(.caption))
                    .foregroundColor(secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 16)
            }

            if visibleTranscriptEntries.isEmpty {
                AudioWaveformView(
                    level: Float(phase == .listening ? inputLevel : outputLevel),
                    tint: phaseColor
                )
                .frame(width: 180, height: 40)
                .opacity(phase == .connecting ? 0.3 : 0.8)
            } else {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 18) {
                                ForEach(Array(visibleTranscriptEntries.enumerated()), id: \.element.id) { index, entry in
                                    transcriptLine(
                                        entry,
                                        isLive: false,
                                        recencyIndex: visibleTranscriptEntries.count - index - 1
                                    )
                                    .id(entry.id)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height, alignment: .center)
                        }
                        .onChange(of: transcriptScrollSignature) { _, _ in
                            guard let next = visibleTranscriptEntries.last?.id else { return }
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(next, anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func transcriptLine(
        _ entry: VoiceSessionTranscriptEntry,
        isLive: Bool,
        recencyIndex: Int
    ) -> some View {
        let isUser = entry.speaker == "You"
        let isSystem = entry.speaker == "System"
        let opacity: Double = switch recencyIndex {
        case 0:
            isLive ? 1.0 : 0.96
        case 1:
            0.72
        case 2:
            0.5
        default:
            0.34
        }
        let textStyle: Font.TextStyle = isUser || isSystem ? .body : .title2
        let fontWeight: Font.Weight = isSystem ? .regular : (isUser ? .regular : .medium)

        return Text(entry.text)
            .font(LitterFont.styled(textStyle, weight: fontWeight))
            .foregroundColor(primaryTextColor.opacity(opacity))
            .multilineTextAlignment(.center)
            .lineSpacing(isUser ? 4 : 6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private var bottomControls: some View {
        HStack(spacing: 40) {
            if let session {
                Button(action: onToggleSpeaker) {
                    VStack(spacing: 6) {
                        Image(systemName: session.route.iconName)
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 52, height: 52)
                            .background(controlFillColor)
                            .clipShape(Circle())

                        Text(session.route.label)
                            .font(LitterFont.monospaced(.caption2, weight: .medium))
                    }
                    .foregroundColor(
                        session.route.supportsSpeakerToggle ? primaryTextColor : secondaryTextColor.opacity(0.6)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!session.route.supportsSpeakerToggle)
            }

            Button(action: onEnd) {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(LitterTheme.textOnAccent)
                    .frame(width: 64, height: 64)
                    .background(LitterTheme.danger)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var realtimeApiKeyPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Realtime needs an API key")
                .font(LitterFont.styled(.headline, weight: .semibold))
                .foregroundColor(primaryTextColor)

            Text("Enter your OpenAI API key for this device. Litter will store it in the local Codex environment as OPENAI_API_KEY.")
                .font(LitterFont.styled(.caption))
                .foregroundColor(secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-...", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(LitterFont.monospaced(.body))
                .foregroundColor(primaryTextColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(controlFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(promptStrokeColor.opacity(1.75), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if let apiKeyError, !apiKeyError.isEmpty {
                Text(apiKeyError)
                    .font(LitterFont.styled(.caption))
                    .foregroundColor(LitterTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            apiKeySaveButton
        }
        .padding(18)
        .frame(maxWidth: 420)
        .background(promptFillColor)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(promptStrokeColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func saveApiKeyAndRetry() {
        guard !trimmedApiKey.isEmpty, !isSavingApiKey else { return }
        guard server?.isLocal == true else {
            apiKeyError = "API keys are only saved on the local server."
            return
        }

        isSavingApiKey = true
        apiKeyError = nil

        Task {
            var apiKeySaved = false
            var authError: String?
            do {
                try OpenAIApiKeyStore.shared.save(trimmedApiKey)
                if case .apiKey? = server?.account {
                    _ = try await appModel.client.logoutAccount(serverId: threadKey.serverId)
                }
                await voiceRuntime.stopActiveVoiceSession()
                try await appModel.restartLocalServer()
                let persisted = OpenAIApiKeyStore.shared.hasStoredKey
                guard persisted else {
                    authError = "API key did not persist locally."
                    throw CancellationError()
                }
                apiKeySaved = true
                authError = nil
            } catch {
                apiKeySaved = false
                if authError == nil {
                    authError = error.localizedDescription
                }
            }

            if apiKeySaved {
                await MainActor.run {
                    isRetryingAfterAuthSave = true
                }
                await voiceRuntime.stopActiveVoiceSession()
                try? await Task.sleep(for: .milliseconds(150))
                do {
                    try await voiceRuntime.startVoiceOnThread(threadKey)
                } catch {
                    await MainActor.run {
                        isRetryingAfterAuthSave = false
                        apiKeyError = error.localizedDescription
                    }
                }
            }

            await MainActor.run {
                isSavingApiKey = false
                hasCheckedAuth = true
                if apiKeySaved {
                    hasStoredApiKey = true
                    apiKey = ""
                }
                if !apiKeySaved {
                    isRetryingAfterAuthSave = false
                    apiKeyError = authError ?? "Failed to save API key"
                }
            }
        }
    }

    @ViewBuilder
    private var apiKeySaveButton: some View {
        Button {
            saveApiKeyAndRetry()
        } label: {
            apiKeySaveButtonLabel
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(controlFillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(promptStrokeColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(trimmedApiKey.isEmpty || isSavingApiKey)
        .opacity(trimmedApiKey.isEmpty || isSavingApiKey ? 0.55 : 1)
    }

    private var apiKeySaveButtonLabel: some View {
        HStack(spacing: 10) {
            if isSavingApiKey {
                ProgressView()
                    .tint(primaryTextColor)
                    .scaleEffect(0.85)
            }
            Text(isSavingApiKey ? "Saving…" : "Save API Key")
                .font(LitterFont.styled(.subheadline, weight: .semibold))
        }
        .foregroundColor(primaryTextColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var phaseColor: Color {
        switch phase {
        case .connecting:
            return Color(hex: glowPalette.accent)
        case .listening:
            return Color(hex: glowPalette.accentStrong)
        case .speaking, .thinking, .handoff:
            return Color(hex: glowPalette.warning)
        case .error:
            return LitterTheme.danger
        }
    }
}

struct GlowPalette: Equatable {
    let background: String
    let accent: String
    let accentStrong: String
    let warning: String
    let success: String
    let danger: String

    static func from(colorScheme: ColorScheme) -> GlowPalette {
        let theme = colorScheme == .dark ? ThemeStore.shared.dark : ThemeStore.shared.light
        return GlowPalette(
            background: theme.background,
            accent: theme.accent,
            accentStrong: theme.accentStrong,
            warning: theme.warning,
            success: theme.success,
            danger: theme.danger
        )
    }
}

private struct VoiceScreenPulsingDot: View {
    let color: Color
    let isActive: Bool

    @State private var scale: CGFloat = 1.0

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .onAppear {
                guard isActive else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    scale = 1.4
                }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        scale = 1.4
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scale = 0.7
                    }
                }
            }
    }
}

private struct SiriEdgeGlow: View {
    let intensity: CGFloat
    let phase: VoiceSessionPhase
    let palette: GlowPalette

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5)) { timeline in
            let _ = timeline.date
            GeometryReader { geometry in
                let cornerRadius: CGFloat = UIScreen.main.displayCornerRadius
                let rect = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                let gradient = makeAngularGradient(for: phase)

                ZStack {
                    rect
                        .strokeBorder(gradient, lineWidth: 4 + intensity * 3)

                    rect
                        .strokeBorder(gradient, lineWidth: 6 + intensity * 4)
                        .blur(radius: 4)

                    rect
                        .strokeBorder(gradient, lineWidth: 8 + intensity * 6)
                        .blur(radius: 12)

                    rect
                        .strokeBorder(gradient, lineWidth: 12 + intensity * 8)
                        .blur(radius: 20)
                        .opacity(0.7)
                }
                .opacity(Double(intensity))
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: phase)
    }

    private func makeAngularGradient(for phase: VoiceSessionPhase) -> AngularGradient {
        let colors = phaseColors(for: phase)
        var positions = (0..<colors.count).map { index in
            let base = Double(index) / Double(colors.count)
            return base + Double.random(in: -0.08...0.08)
        }.sorted()
        positions = positions.map { min(1, max(0, $0)) }

        let stops = zip(colors, positions).map { color, position in
            Gradient.Stop(color: color, location: position)
        }
        return AngularGradient(gradient: Gradient(stops: stops), center: .center)
    }

    private func phaseColors(for phase: VoiceSessionPhase) -> [Color] {
        let accent = Color(hex: palette.accent)
        let accentStrong = Color(hex: palette.accentStrong)
        let warning = Color(hex: palette.warning)
        let success = Color(hex: palette.success)
        let danger = Color(hex: palette.danger)

        switch phase {
        case .listening:
            return [
                accentStrong,
                accentStrong.opacity(0.7),
                accent,
                success,
                accentStrong.opacity(0.5),
                accent.opacity(0.8),
            ]
        case .speaking:
            return [
                warning,
                warning.opacity(0.7),
                warning.opacity(0.9),
                warning.opacity(0.5),
                warning.opacity(0.8),
                warning.opacity(0.6),
            ]
        case .thinking, .handoff:
            return [
                warning.opacity(0.6),
                accent.opacity(0.4),
                warning.opacity(0.4),
                accentStrong.opacity(0.3),
                warning.opacity(0.5),
                accent.opacity(0.3),
            ]
        case .connecting:
            return [
                accent.opacity(0.4),
                accentStrong.opacity(0.3),
                accent.opacity(0.2),
                Color.gray.opacity(0.2),
                accent.opacity(0.3),
                accentStrong.opacity(0.2),
            ]
        case .error:
            return [
                danger,
                danger.opacity(0.6),
                danger.opacity(0.5),
                danger.opacity(0.4),
                danger.opacity(0.3),
                danger.opacity(0.5),
            ]
        }
    }
}

private extension UIScreen {
    var displayCornerRadius: CGFloat {
        let key = "_displayCornerRadius"
        guard let value = self.value(forKey: key) as? CGFloat, value > 0 else {
            return 50
        }
        return value
    }
}
