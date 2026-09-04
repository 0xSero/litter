import SwiftUI
import UIKit

/// Full-screen terminal. The Ghostty surface fills the entire body —
/// keystrokes go straight to the PTY via the hidden first-responder text
/// field, and the Esc/Ctrl/Tab/arrows row docks above the system keyboard
/// as an input accessory view (set up inside `GhosttyHostView`).
///
/// The header (backend chip + "Aa" appearance button) sits on top; we keep
/// the SSH trust banner as a transient overlay when needed.
struct TerminalScreen: View {
    let cwd: String?
    var preferredAlleycatNodeId: String? = nil

    @State private var controller = TerminalSessionController()
    @State private var backendOptions: [TerminalBackendOption] = []
    @State private var selectedBackendID: String?
    @State private var didStart = false
    @State private var terminalGridSize = TerminalGridSize(cols: 80, rows: 24)
    @State private var terminalSurfaceSize: CGSize = .zero
    @State private var ghosttyRenderer = GhosttyTerminalRenderer()
    @State private var nativeRendererHasOutput = false
    @State private var showConfigSheet = false
    @State private var snapshotObserver = AppSnapshotObserver()
    /// Identity of the server list the current `backendOptions` were built
    /// from, so the observer only reconciles when servers actually change.
    @State private var observedServerFingerprint: String?
    @AppStorage("litter.terminal.fontSize") private var storedFontSize: Double = 13.0
    @AppStorage("litter.terminal.themeId") private var storedThemeId: String = "litter-dark"
    @AppStorage("litter.terminal.cursorBlink") private var storedCursorBlink: Bool = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private let accent = Color(red: 0, green: 1, blue: 0.612)
    private let alleycatServerIdPrefix = "alleycat:"

    var body: some View {
        GeometryReader { geometry in
            let terminalInsets = terminalHorizontalInsets(for: geometry)

            VStack(spacing: 0) {
                terminalNavigationBar(topInset: geometry.safeAreaInsets.top)
                backendBar
                terminalSurface(
                    contentLeadingInset: terminalInsets.leading,
                    contentTrailingInset: terminalInsets.trailing
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(Color.black)
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: [.top, .bottom, .horizontal])
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .toolbar(.hidden, for: .navigationBar)
        .alert("SSH Host Identity Changed", isPresented: Binding(
            get: { controller.sshTrustChallenge?.isChanged == true },
            set: { if !$0 { controller.dismissSshTrustChallenge() } }
        )) {
            Button("Replace Stored Identity", role: .destructive) {
                Task { await controller.trustUnknownSshHostAndRetry() }
            }
            Button("Cancel", role: .cancel) {
                controller.dismissSshTrustChallenge()
            }
        } message: {
            Text("The SSH identity for this server changed. This can happen after a server is recreated, but may also indicate a man-in-the-middle attack. New fingerprint: \(controller.sshTrustChallenge?.fingerprint ?? "unknown")")
        }
        .task {
            attachOutputSink()
            // Reconcile the backend chooser when the connected-server list
            // changes. This used to be `.onChange(of: appSnapshotRevision)` in
            // `body`, which re-rendered the whole terminal (Ghostty surface
            // included) at the ~8 fps streaming snapshot cadence.
            snapshotObserver.start(appModel: AppModel.shared) { reconcileBackendOptionsIfServersChanged() }
            guard !didStart else { return }
            didStart = true
            let options = refreshBackendOptions()
            let initial = initialBackend(from: options, cwd: cwd)
            selectedBackendID = initial.id
            await controller.open(backend: initial.backend)
            applyConfigSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .litterSavedServersDidChange)) { _ in
            reconcileBackendOptions()
        }
        .onDisappear {
            snapshotObserver.stop()
            // End any active first-responder hold so the keyboard tears
            // down and SwiftUI releases first responder. Without this the
            // keyboard can linger after navigating back, leaving the
            // parent screen unable to receive touches until the OS gives
            // up on the detached responder chain.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
            controller.setOutputSink(nil)
            controller.close()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                ghosttyRenderer.setOccluded(false)
            case .inactive, .background:
                ghosttyRenderer.setOccluded(true)
            @unknown default:
                break
            }
        }
    }

    private func terminalNavigationBar(topInset: CGFloat) -> some View {
        ZStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 54, height: 54)
                        .background(Color.white.opacity(0.09))
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Spacer(minLength: 0)
            }

            Text("Terminal")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.top, topInset + 8)
        .frame(height: topInset + 86)
        .background(Color.black)
    }

    private func terminalHorizontalInsets(for geometry: GeometryProxy) -> (leading: CGFloat, trailing: CGFloat) {
        let leading = max(geometry.safeAreaInsets.leading, 0)
        let trailing = max(geometry.safeAreaInsets.trailing, 0)
        guard UIDevice.current.userInterfaceIdiom == .phone,
              leading == 0,
              trailing == 0,
              geometry.size.width > geometry.size.height else {
            return (leading, trailing)
        }
        return (58, 58)
    }

    private var selectedBackend: TerminalBackendOption? {
        backendOptions.first { $0.id == selectedBackendID } ?? backendOptions.first
    }

    private func attachOutputSink() {
        let renderer = ghosttyRenderer
        let outputSink = renderer.makeOutputSink()
        controller.setOutputSink { data in
            outputSink(data)
        }
    }

    private var backendBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(backendOptions) { option in
                    Button {
                        selectBackend(option)
                    } label: {
                        Label(option.title, systemImage: option.systemImage)
                    }
                }
                if backendOptions.count <= 1 {
                    Divider()
                    Button("No remote terminal servers") {}
                        .disabled(true)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedBackend?.systemImage ?? "terminal")
                    Text(selectedBackend?.title ?? "Local iSH")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(.custom("SFMono-Regular", size: 12))
                .foregroundColor(accent)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Text(selectedBackend?.subtitle ?? "On device")
                .font(.custom("SFMono-Regular", size: 11))
                .foregroundColor(.white.opacity(0.48))
                .lineLimit(1)

            Spacer(minLength: 0)

            phaseChip

            Button {
                showConfigSheet = true
            } label: {
                Text("Aa")
                    .font(.custom("SFMono-Regular", size: 13))
                    .foregroundColor(accent)
                    .frame(width: 34, height: 30)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityLabel("Theme and font")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .sheet(isPresented: $showConfigSheet) {
            TerminalConfigSheet(
                fontSize: $storedFontSize,
                themeId: $storedThemeId,
                cursorBlink: $storedCursorBlink,
                onApply: { fontSize, themeId, cursorBlink in
                    applyConfigSettings(
                        fontSize: fontSize,
                        themeId: themeId,
                        cursorBlink: cursorBlink,
                        regrid: true
                    )
                }
            )
        }
    }

    private var phaseChip: some View {
        HStack(spacing: 4) {
            Image(systemName: phaseIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(phaseLabel)
                .font(.custom("SFMono-Regular", size: 11))
                .lineLimit(1)
        }
        .foregroundColor(phaseColor)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(phaseColor.opacity(0.12))
        .clipShape(Capsule())
    }

    private func terminalSurface(
        contentLeadingInset: CGFloat,
        contentTrailingInset: CGFloat
    ) -> some View {
        GeometryReader { geometry in
            let leadingInset = max(contentLeadingInset, 0)
            let trailingInset = max(contentTrailingInset, 0)
            let contentWidth = max(1, geometry.size.width - leadingInset - trailingInset)
            let contentSize = CGSize(width: contentWidth, height: geometry.size.height)
            let background = terminalSurfaceBackground

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(background)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .topLeading
                    )

                ZStack(alignment: .topLeading) {
                    GhosttyTerminalView(
                        renderer: ghosttyRenderer,
                        onNativeOutputVisibilityChanged: { visible in
                            nativeRendererHasOutput = visible
                        },
                        onInput: { data in
                            Task { await controller.send(data) }
                        },
                        onClearTapped: {
                            controller.clearOutput()
                            ghosttyRenderer.clearScreen()
                            nativeRendererHasOutput = false
                        },
                        onSendToAssistant: sendOutputToAssistant,
                        onFontSizePinched: { newSize in
                            storedFontSize = newSize
                            applyConfigSettings(
                                fontSize: newSize,
                                themeId: storedThemeId,
                                cursorBlink: storedCursorBlink,
                                regrid: true
                            )
                        },
                        fontSize: storedFontSize
                    )
                    .frame(
                        width: contentWidth,
                        height: geometry.size.height,
                        alignment: .topLeading
                    )
                    .background(background)

                    if shouldShowStatusOverlay {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(displayText)
                                .font(.custom("SFMono-Regular", size: storedFontSize))
                                .foregroundColor(phaseColor)
                                .textSelection(.enabled)
                            if let challenge = controller.sshTrustChallenge {
                                Button {
                                    Task { await controller.trustUnknownSshHostAndRetry() }
                                } label: {
                                    Label("Trust \(challenge.fingerprint)", systemImage: "key.fill")
                                        .font(.custom("SFMono-Regular", size: 12))
                                        .foregroundColor(.black)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .padding(.horizontal, 10)
                                        .frame(height: 32)
                                        .background(accent)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
                .frame(
                    width: contentWidth,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
                .offset(x: leadingInset)
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .background(background)
            .onAppear {
                updateTerminalContentSize(contentSize)
                DispatchQueue.main.async {
                    applyConfigSettings()
                }
            }
            .onChange(of: contentSize) { _, size in
                updateTerminalContentSize(size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateTerminalContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        DispatchQueue.main.async {
            if terminalSurfaceSize != size {
                terminalSurfaceSize = size
            }
            scheduleTerminalRegrid(for: size)
        }
    }

    private var terminalSurfaceBackground: Color {
        if storedThemeId == TerminalThemeChoice.litterDark.rawValue {
            return Color(hex: "#282C34")
        }
        return Color(hex: themePalette(preset: TerminalThemeChoice.preset(forId: storedThemeId)).background)
    }

    private var displayText: String {
        if !controller.output.isEmpty {
            return controller.output
        }
        switch controller.phase {
        case .idle, .connecting:
            return "Connecting...\n"
        case .running:
            return ""
        case .exited(let code):
            return "\n[process exited \(code)]\n"
        case .failed(let message):
            return "\n[terminal failed: \(message)]\n"
        }
    }

    private var shouldShowStatusOverlay: Bool {
        if !controller.output.isEmpty {
            return !nativeRendererHasOutput
        }
        switch controller.phase {
        case .idle, .connecting, .failed, .exited:
            return true
        case .running:
            return false
        }
    }

    private var phaseIcon: String {
        switch controller.phase {
        case .idle, .connecting: return "circle.dotted"
        case .running: return "terminal"
        case .exited: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .idle, .connecting: return .white.opacity(0.45)
        case .running: return accent
        case .exited: return .white.opacity(0.5)
        case .failed: return .red
        }
    }

    private var phaseLabel: String {
        switch controller.phase {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .running: return selectedBackend?.runningLabel ?? "running"
        case .exited(let code): return "exited \(code)"
        case .failed: return "failed"
        }
    }

    /// Forward terminal text to the assistant on the current active
    /// thread. If a painted selection is active, prefer that text; else
    /// send the visible viewport.
    private func sendOutputToAssistant() {
        guard let threadKey = AppModel.shared.snapshot?.activeThread else { return }
        let selection = ghosttyRenderer.readSelection()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = controller.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = (selection?.isEmpty == false ? selection : nil) ?? fallback
        guard !payload.isEmpty else { return }
        Task {
            try? await ghosttyRenderer.sendTextToAssistant(
                store: AppModel.shared.store,
                threadKey: threadKey,
                selection: payload
            )
        }
    }

    private func initialBackend(
        from options: [TerminalBackendOption],
        cwd: String?
    ) -> TerminalBackendOption {
        if let preferredNodeId = normalized(preferredAlleycatNodeId),
           let match = options.first(where: { $0.alleycatNodeId == preferredNodeId }) {
            return match
        }
        return options.first ?? TerminalBackendOption.localIsh(cwd: cwd)
    }

    private func selectBackend(_ option: TerminalBackendOption) {
        guard selectedBackendID != option.id else { return }
        selectedBackendID = option.id
        attachOutputSink()
        ghosttyRenderer.clearScreen()
        nativeRendererHasOutput = false
        Task {
            await controller.switchBackend(option.backend)
        }
    }

    /// Recompute PTY cols/rows. Prefer the renderer's live cell metrics —
    /// they're driven by Ghostty's actual font measurement so font-size
    /// changes, rotation, and keyboard show/hide all yield correct grids.
    /// Falls back to a font-size-aware estimate only when the renderer
    /// hasn't yet reported metrics (first frame of attach).
    private func resizeTerminal(for size: CGSize) {
        let scale = UIScreen.main.scale
        let grid: TerminalGridSize
        if let metrics = ghosttyRenderer.surfaceMetrics(),
           TerminalGridSize.metricsAreCurrent(metrics, for: size, contentScale: scale) {
            grid = TerminalGridSize(metrics: metrics)
        } else {
            grid = TerminalGridSize(estimatedFor: size, fontSize: storedFontSize)
        }
        ghosttyRenderer.setGridSize(cols: grid.cols, rows: grid.rows)
        guard grid != terminalGridSize else { return }
        terminalGridSize = grid
        let notifyBackend = selectedBackend?.supportsResize == true
        Task {
            await controller.resize(cols: grid.cols, rows: grid.rows, notifyBackend: notifyBackend)
        }
    }

    private func loadBackendOptions(cwd: String?) -> [TerminalBackendOption] {
        var options = [TerminalBackendOption.localIsh(cwd: cwd)]
        var seenNodeIds = Set<String>()
        var seenSshKeys = Set<String>()
        let savedServers = SavedServerStore.load()
        let savedByNodeId = savedServers.reduce(into: [String: SavedServer]()) { result, saved in
            guard let nodeId = normalized(saved.alleycatNodeId),
                  result[nodeId] == nil else {
                return
            }
            result[nodeId] = saved
        }
        for server in AppModel.shared.snapshot?.servers ?? [] {
            guard let nodeId = alleycatNodeId(fromServerId: server.serverId),
                  seenNodeIds.insert(nodeId).inserted,
                  let token = try? AlleycatCredentialStore.shared.loadToken(nodeId: nodeId),
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let saved = savedByNodeId[nodeId]
            options.append(
                TerminalBackendOption.remoteAlleycat(
                    name: normalized(saved?.name) ?? server.displayName,
                    nodeId: nodeId,
                    token: token,
                    relay: normalized(saved?.alleycatRelay)
                )
            )
        }
        // Include non-remembered discovered records too: if they have a
        // terminal-capable credential, the chooser should be able to switch
        // to them while the app still knows about the connection.
        for saved in savedServers {
            if let nodeId = normalized(saved.alleycatNodeId),
               seenNodeIds.insert(nodeId).inserted,
               let token = try? AlleycatCredentialStore.shared.loadToken(nodeId: nodeId),
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                options.append(
                    TerminalBackendOption.remoteAlleycat(
                        name: saved.name,
                        nodeId: nodeId,
                        token: token,
                        relay: normalized(saved.alleycatRelay)
                    )
                )
                continue
            }

            let host = saved.hostname
            let sshPort = saved.sshPort ?? 22
            let sshKey = "\(host.lowercased()):\(sshPort)"
            guard !host.isEmpty, seenSshKeys.insert(sshKey).inserted else { continue }
            guard let credential = (try? SSHCredentialStore.shared.load(host: host, port: Int(sshPort))) ?? nil,
                  let sshAuth = Self.terminalSshAuth(from: credential) else {
                continue
            }
            options.append(
                TerminalBackendOption.remoteSsh(
                    name: saved.name,
                    host: host,
                    port: sshPort,
                    username: credential.username,
                    auth: sshAuth
                )
            )
        }
        return options
    }

    @discardableResult
    private func refreshBackendOptions() -> [TerminalBackendOption] {
        let options = loadBackendOptions(cwd: cwd)
        backendOptions = options
        return options
    }

    /// Observer-driven reconcile. `loadBackendOptions` reads the keychain for
    /// every server, so gate it on the connected-server identity actually
    /// changing rather than rebuilding on every snapshot revision.
    private func reconcileBackendOptionsIfServersChanged() {
        let fingerprint = (AppModel.shared.snapshot?.servers ?? [])
            .map { "\($0.serverId)\u{1}\($0.displayName)" }
            .joined(separator: "\u{2}")
        guard observedServerFingerprint != fingerprint else { return }
        observedServerFingerprint = fingerprint
        reconcileBackendOptions()
    }

    private func reconcileBackendOptions() {
        let options = refreshBackendOptions()
        guard let selectedBackendID,
              options.contains(where: { $0.id == selectedBackendID }) else {
            self.selectedBackendID = initialBackend(from: options, cwd: cwd).id
            return
        }
    }

    private static func terminalSshAuth(from credential: SavedSSHCredential) -> TerminalSshAuth? {
        switch credential.method {
        case .password:
            guard let password = credential.password, !password.isEmpty else { return nil }
            return .password(password: password)
        case .key:
            guard let key = credential.privateKey, !key.isEmpty else { return nil }
            return .privateKey(keyPem: key, passphrase: credential.passphrase)
        }
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func alleycatNodeId(fromServerId serverId: String) -> String? {
        let trimmed = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(alleycatServerIdPrefix) else { return nil }
        return normalized(String(trimmed.dropFirst(alleycatServerIdPrefix.count)))
    }

    private func applyConfigSettings() {
        applyConfigSettings(
            fontSize: storedFontSize,
            themeId: storedThemeId,
            cursorBlink: storedCursorBlink
        )
    }

    private func applyConfigSettings(
        fontSize: Double,
        themeId: String,
        cursorBlink: Bool,
        regrid: Bool = false
    ) {
        let config = TerminalConfig(
            theme: TerminalThemeChoice.preset(forId: themeId),
            fontFamily: "SFMono-Regular",
            fontSizePt: Float(fontSize),
            cursorStyle: .bar,
            cursorBlink: cursorBlink,
            scrollbackLines: 10_000
        )
        ghosttyRenderer.applyConfig(config)
        if regrid {
            scheduleTerminalRegrid()
        }
    }

    private func scheduleTerminalRegrid(for explicitSize: CGSize? = nil) {
        let size = explicitSize ?? terminalSurfaceSize
        guard size.width > 0, size.height > 0 else { return }
        for delay in [0.0, 0.05, 0.16, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let latestSize = terminalSurfaceSize
                guard latestSize.width > 0, latestSize.height > 0 else { return }
                resizeTerminal(for: latestSize)
            }
        }
    }
}

private enum TerminalThemeChoice: String, CaseIterable, Identifiable {
    case litterDark = "litter-dark"
    case catppuccinFrappe = "catppuccin-frappe"
    case catppuccinFrappeLight = "catppuccin-frappe-light"
    case solarizedDark = "solarized-dark"
    case solarizedLight = "solarized-light"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .litterDark: return "Litter Dark"
        case .catppuccinFrappe: return "Catppuccin Frappé"
        case .catppuccinFrappeLight: return "Catppuccin Frappé Light"
        case .solarizedDark: return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        }
    }

    var preset: TerminalThemePreset {
        switch self {
        case .litterDark: return .litterDark
        case .catppuccinFrappe: return .catppuccinFrappe
        case .catppuccinFrappeLight: return .catppuccinFrappeLight
        case .solarizedDark: return .solarized(dark: true)
        case .solarizedLight: return .solarized(dark: false)
        }
    }

    static func preset(forId id: String) -> TerminalThemePreset {
        (TerminalThemeChoice(rawValue: id) ?? .litterDark).preset
    }
}

private struct TerminalConfigSheet: View {
    @Binding var fontSize: Double
    @Binding var themeId: String
    @Binding var cursorBlink: Bool
    let onApply: (Double, String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draftFontSize: Double
    @State private var draftThemeId: String
    @State private var draftCursorBlink: Bool
    @State private var appliedForDismiss = false

    init(
        fontSize: Binding<Double>,
        themeId: Binding<String>,
        cursorBlink: Binding<Bool>,
        onApply: @escaping (Double, String, Bool) -> Void
    ) {
        self._fontSize = fontSize
        self._themeId = themeId
        self._cursorBlink = cursorBlink
        self.onApply = onApply
        self._draftFontSize = State(initialValue: fontSize.wrappedValue)
        self._draftThemeId = State(initialValue: themeId.wrappedValue)
        self._draftCursorBlink = State(initialValue: cursorBlink.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Font") {
                    Stepper(value: $draftFontSize, in: 10...24, step: 1) {
                        HStack {
                            Text("Size")
                                .font(.custom("SFMono-Regular", size: 13))
                            Spacer()
                            Text("\(Int(draftFontSize)) pt")
                                .font(.custom("SFMono-Regular", size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                    Slider(
                        value: $draftFontSize,
                        in: 10...24,
                        step: 1
                    ) {
                        Text("Size")
                    }
                }
                .onChange(of: draftFontSize) { _, _ in
                    applyDraft()
                }
                Section("Theme") {
                    Picker("Theme", selection: $draftThemeId) {
                        ForEach(TerminalThemeChoice.allCases) { choice in
                            Text(choice.title).tag(choice.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: draftThemeId) { _, _ in applyDraft() }
                }
                Section("Cursor") {
                    Toggle("Blink", isOn: $draftCursorBlink)
                        .onChange(of: draftCursorBlink) { _, _ in applyDraft() }
                }
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        applyDraft()
                        appliedForDismiss = true
                        dismiss()
                    }
                }
            }
            .onDisappear {
                if !appliedForDismiss {
                    applyDraft()
                }
            }
        }
    }

    private func applyDraft() {
        fontSize = draftFontSize
        themeId = draftThemeId
        cursorBlink = draftCursorBlink
        onApply(draftFontSize, draftThemeId, draftCursorBlink)
    }
}

private struct TerminalBackendOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let alleycatNodeId: String?
    let supportsResize: Bool
    let runningLabel: String
    let backend: TerminalBackendKind

    static func localIsh(cwd: String?) -> TerminalBackendOption {
        TerminalBackendOption(
            id: "local-ish",
            title: "Local iSH",
            subtitle: cwd?.isEmpty == false ? cwd! : "/root",
            systemImage: "iphone",
            alleycatNodeId: nil,
            supportsResize: true,
            runningLabel: "running",
            backend: .localIsh(cwd: normalized(cwd))
        )
    }

    static func remoteAlleycat(
        name: String,
        nodeId: String,
        token: String,
        relay: String?
    ) -> TerminalBackendOption {
        TerminalBackendOption(
            id: "alleycat-\(nodeId)",
            title: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Remote shell" : name,
            subtitle: shortNodeId(nodeId),
            systemImage: "server.rack",
            alleycatNodeId: nodeId,
            supportsResize: true,
            runningLabel: "remote",
            backend: .remoteAlleycat(
                nodeId: nodeId,
                token: token,
                relay: relay,
                shell: nil
            )
        )
    }

    static func remoteSsh(
        name: String,
        host: String,
        port: UInt16,
        username: String,
        auth: TerminalSshAuth
    ) -> TerminalBackendOption {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedName.isEmpty ? "\(username)@\(host)" : trimmedName
        return TerminalBackendOption(
            id: "ssh-\(host.lowercased()):\(port)",
            title: title,
            subtitle: "ssh \(username)@\(host):\(port)",
            systemImage: "terminal.fill",
            alleycatNodeId: nil,
            supportsResize: true,
            runningLabel: "ssh",
            backend: .remoteSsh(
                host: host,
                port: port,
                username: username,
                auth: auth,
                shell: nil,
                acceptUnknownHost: false,
                cwd: nil
            )
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shortNodeId(_ raw: String) -> String {
        raw.count <= 16 ? raw : "\(raw.prefix(8))...\(raw.suffix(8))"
    }
}

private struct TerminalGridSize: Equatable {
    let cols: UInt16
    let rows: UInt16

    init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }

    init(metrics: LitterGhosttySurfaceMetrics) {
        cols = UInt16(max(20, min(240, Int(metrics.columns))))
        rows = UInt16(max(4, min(120, Int(metrics.rows))))
    }

    static func metricsAreCurrent(
        _ metrics: LitterGhosttySurfaceMetrics,
        for size: CGSize,
        contentScale: CGFloat
    ) -> Bool {
        guard metrics.cellWidthPx > 0, metrics.cellHeightPx > 0 else { return false }
        let expectedWidth = Int(round(max(0, size.width * contentScale)))
        let expectedHeight = Int(round(max(0, size.height * contentScale)))
        let actualWidth = Int(metrics.widthPx)
        let actualHeight = Int(metrics.heightPx)
        return abs(actualWidth - expectedWidth) <= 2
            && abs(actualHeight - expectedHeight) <= 2
    }

    /// Derive cols/rows from the live cell metrics Ghostty reports. Pixel
    /// values come from `ghostty_surface_size`, view bounds come from
    /// SwiftUI; divide the latter (in pixels) by the former to get a
    /// grid that lines up exactly with what Ghostty paints.
    init(size: CGSize, contentScale: CGFloat, cellWidthPx: CGFloat, cellHeightPx: CGFloat) {
        let widthPx = max(0, size.width * contentScale)
        let heightPx = max(0, size.height * contentScale)
        let computedCols = Int(floor(widthPx / max(cellWidthPx, 1)))
        let computedRows = Int(floor(heightPx / max(cellHeightPx, 1)))
        cols = UInt16(max(20, min(240, computedCols)))
        rows = UInt16(max(4, min(120, computedRows)))
    }

    /// First-frame fallback used before the renderer has produced metrics.
    /// Estimate cell dimensions from the chosen font size so the initial
    /// PTY grid is in the right ballpark across the 10–24 pt range.
    init(estimatedFor size: CGSize, fontSize: Double) {
        let cellWidth = max(6.0, fontSize * 0.6)
        let cellHeight = max(12.0, fontSize * 1.31)
        let contentWidth = max(0, size.width)
        let contentHeight = max(0, size.height)
        let computedCols = Int(contentWidth / cellWidth)
        let computedRows = Int(contentHeight / cellHeight)
        cols = UInt16(max(20, min(240, computedCols)))
        rows = UInt16(max(4, min(120, computedRows)))
    }
}

#if DEBUG
#Preview("Terminal") {
    NavigationStack {
        TerminalScreen(cwd: "/root")
    }
}
#endif
