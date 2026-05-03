import AVFoundation
import SwiftUI
import UIKit

struct AlleycatConnectedTarget: Equatable {
    let serverId: String
    let nodeId: String
    let displayName: String
    let params: AppAlleycatPairPayload
    let agentName: String
    let agentWire: AppAlleycatAgentWire
}

struct AlleycatAddServerSheet: View {
    let appModel: AppModel
    let startScanningOnAppear: Bool
    let onConnected: (AlleycatConnectedTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String = ""
    @State private var parsedParams: AppAlleycatPairPayload?
    @State private var agents: [AppAlleycatAgentInfo] = []
    @State private var selectedAgentNames: Set<String> = []
    @State private var isLoadingAgents = false
    @State private var parseError: String?
    @State private var agentError: String?
    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var showScanner = false
    @State private var didRequestInitialScan = false
    @State private var cameraDenied = false
    #if DEBUG
    @State private var pasteJSON: String = ""
    @State private var showPaste: Bool = false
    #endif

    private let alleycat = RustAlleycatBridge.shared

    init(
        appModel: AppModel,
        startScanningOnAppear: Bool = false,
        onConnected: @escaping (AlleycatConnectedTarget) -> Void
    ) {
        self.appModel = appModel
        self.startScanningOnAppear = startScanningOnAppear
        self.onConnected = onConnected
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    pairingSection
                    if let params = parsedParams {
                        previewSection(params: params)
                        agentSection
                    }
                    if let parseError {
                        errorSection(parseError, color: LitterTheme.warning)
                    }
                    if let agentError {
                        errorSection(agentError, color: LitterTheme.warning)
                    }
                    connectSection
                    if let connectError {
                        errorSection(connectError, color: LitterTheme.danger)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Remote Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
        .onAppear {
            requestInitialScanIfNeeded()
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerScreen(
                onScan: { scanned in
                    showScanner = false
                    handleScannedPayload(scanned)
                },
                onCancel: {
                    showScanner = false
                    if startScanningOnAppear, parsedParams == nil {
                        dismiss()
                    }
                },
                onPermissionDenied: {
                    showScanner = false
                    cameraDenied = true
                }
            )
        }
        .alert(
            "Camera Access Needed",
            isPresented: $cameraDenied,
            actions: {
                Button("Open Settings") { openAppSettings() }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("Allow camera access in Settings to scan an Alleycat pairing QR code.")
            }
        )
    }

    private func requestInitialScanIfNeeded() {
        guard startScanningOnAppear, !didRequestInitialScan, parsedParams == nil else { return }
        didRequestInitialScan = true
        Task { @MainActor in
            await Task.yield()
            requestCameraAndScan()
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                requestCameraAndScan()
            } label: {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundColor(LitterTheme.accent)
                    Text(parsedParams == nil ? "Scan Pairing QR" : "Rescan QR")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.accent)
                }
            }

            #if DEBUG
            DisclosureGroup(
                isExpanded: $showPaste,
                content: {
                    TextEditor(text: $pasteJSON)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                        .overlay(alignment: .topLeading) {
                            if pasteJSON.isEmpty {
                                Text(#"{"v":1,"node_id":"...","token":"...","relay":"https://..."}"#)
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textMuted)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button("Parse JSON") {
                        handleScannedPayload(pasteJSON)
                    }
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.accent)
                    .disabled(pasteJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                },
                label: {
                    Text("Paste JSON (debug)")
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textSecondary)
                }
            )
            #endif
        } header: {
            Text("Pairing")
                .foregroundColor(LitterTheme.textSecondary)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private func previewSection(params: AppAlleycatPairPayload) -> some View {
        Section {
            previewRow(label: "node", value: shortNodeId(params.nodeId))
            previewRow(label: "protocol", value: "v\(params.v)")
            if let relay = params.relay, !relay.isEmpty {
                previewRow(label: "relay", value: relay)
            }
            if let hostName = params.hostName, !hostName.isEmpty {
                previewRow(label: "host", value: hostName)
            }
            TextField("display name (optional)", text: $displayName)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        } header: {
            Text("Scanned Host")
                .foregroundColor(LitterTheme.textSecondary)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var agentSection: some View {
        Section {
            if isLoadingAgents {
                HStack {
                    ProgressView().tint(LitterTheme.accent)
                    Text("Loading agents")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
            } else if agents.isEmpty {
                Text("No agents are available on this host.")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted)
            } else {
                ForEach(agents, id: \.name) { agent in
                    Button {
                        guard agent.available else { return }
                        toggleAgentSelection(agent)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.displayName)
                                    .litterFont(.subheadline)
                                    .foregroundColor(agent.available ? LitterTheme.textPrimary : LitterTheme.textMuted)
                                Text(wireLabel(agent.wire))
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                            Spacer()
                            if selectedAgentNames.contains(agent.name) {
                                Image(systemName: "checkmark.square.fill")
                                    .foregroundColor(LitterTheme.accent)
                            } else if !agent.available {
                                Text("Unavailable")
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textMuted)
                            } else {
                                Image(systemName: "square")
                                    .foregroundColor(LitterTheme.textMuted)
                            }
                        }
                    }
                    .disabled(!agent.available)
                }
            }
        } header: {
            HStack {
                Text("Agents")
                Spacer()
                if !availableAgents.isEmpty {
                    Button(selectedAgents.count == availableAgents.count ? "None" : "All") {
                        if selectedAgents.count == availableAgents.count {
                            selectedAgentNames = []
                        } else {
                            selectedAgentNames = Set(availableAgents.map(\.name))
                        }
                    }
                    .font(.caption)
                    .foregroundColor(LitterTheme.accent)
                }
            }
                .foregroundColor(LitterTheme.textSecondary)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private func previewRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textSecondary)
            Spacer()
            Text(value)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var connectSection: some View {
        Section {
            Button {
                connect()
            } label: {
                HStack {
                    if isConnecting {
                        ProgressView().tint(LitterTheme.accent)
                    }
                    Text("Connect")
                        .foregroundColor(LitterTheme.accent)
                        .litterFont(.subheadline)
                }
            }
            .disabled(!canConnect)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private func errorSection(_ message: String, color: Color) -> some View {
        Section {
            Text(message)
                .litterFont(.caption)
                .foregroundColor(color)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var availableAgents: [AppAlleycatAgentInfo] {
        agents.filter(\.available)
    }

    private var selectedAgents: [AppAlleycatAgentInfo] {
        agents.filter { $0.available && selectedAgentNames.contains($0.name) }
    }

    private var canConnect: Bool {
        !isConnecting && !isLoadingAgents && parsedParams != nil && !selectedAgents.isEmpty
    }

    private func toggleAgentSelection(_ agent: AppAlleycatAgentInfo) {
        if selectedAgentNames.contains(agent.name) {
            selectedAgentNames.remove(agent.name)
        } else {
            selectedAgentNames.insert(agent.name)
        }
    }

    private func handleScannedPayload(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let params = try alleycat.parsePairPayload(json: trimmed)
            parsedParams = params
            displayName = suggestedDisplayName(for: params)
            parseError = nil
            connectError = nil
            agentError = nil
            agents = []
            selectedAgentNames = []
            loadAgents(params: params)
        } catch {
            parsedParams = nil
            agents = []
            selectedAgentNames = []
            parseError = error.localizedDescription
        }
    }

    private func loadAgents(params: AppAlleycatPairPayload) {
        isLoadingAgents = true
        Task {
            do {
                let loaded = try await appModel.serverBridge.listAlleycatAgents(params: params)
                await MainActor.run {
                    guard parsedParams?.nodeId == params.nodeId else { return }
                    agents = loaded
                    selectedAgentNames = Set(loaded.filter(\.available).map(\.name))
                    isLoadingAgents = false
                    agentError = nil
                }
            } catch {
                await MainActor.run {
                    guard parsedParams?.nodeId == params.nodeId else { return }
                    agents = []
                    selectedAgentNames = []
                    isLoadingAgents = false
                    agentError = error.localizedDescription
                }
            }
        }
    }

    private func connect() {
        guard let params = parsedParams, let fallbackAgent = selectedAgents.first else { return }
        let trimmedDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedDisplay.isEmpty ? suggestedDisplayName(for: params) : trimmedDisplay
        let selectedNames = selectedAgents.map(\.name)
        let serverId = "alleycat:\(params.nodeId)"

        isConnecting = true
        connectError = nil

        Task {
            do {
                let result = try await appModel.serverBridge.connectRemoteOverAlleycat(
                    serverId: serverId,
                    displayName: resolvedName,
                    params: params,
                    agentName: fallbackAgent.name,
                    selectedAgentNames: selectedNames,
                    wire: fallbackAgent.wire
                )
                do {
                    try AlleycatCredentialStore.shared.saveToken(params.token, nodeId: params.nodeId)
                } catch {
                    NSLog("[ALLEYCAT_CREDENTIALS] keychain save failed: %@", error.localizedDescription)
                }

                await MainActor.run {
                    isConnecting = false
                    onConnected(
                        AlleycatConnectedTarget(
                            serverId: result.serverId,
                            nodeId: result.nodeId,
                            displayName: resolvedName,
                            params: params,
                            agentName: result.agentName,
                            agentWire: fallbackAgent.wire
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    connectError = error.localizedDescription
                }
            }
        }
    }

    private func requestCameraAndScan() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            showScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        showScanner = true
                    } else {
                        cameraDenied = true
                    }
                }
            }
        case .denied, .restricted:
            cameraDenied = true
        @unknown default:
            cameraDenied = true
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func suggestedDisplayName(for params: AppAlleycatPairPayload) -> String {
        let hostName = params.hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hostName.isEmpty {
            return hostName
        }
        return "Alleycat \(shortNodeId(params.nodeId))"
    }

    private func shortNodeId(_ raw: String) -> String {
        if raw.count <= 16 { return raw }
        return "\(raw.prefix(8))...\(raw.suffix(8))"
    }

    private func wireLabel(_ wire: AppAlleycatAgentWire) -> String {
        switch wire {
        case .websocket:
            return "websocket"
        case .jsonl:
            return "jsonl"
        }
    }
}

// MARK: - QR Scanner

private struct QRScannerScreen: View {
    let onScan: (String) -> Void
    let onCancel: () -> Void
    let onPermissionDenied: () -> Void

    private static let pairCommand = "npx kittylitter"

    @State private var copied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            QRCaptureSheet(
                onScan: onScan,
                onCancel: onCancel,
                onPermissionDenied: onPermissionDenied
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 16) {
                topBar
                instructionsCard
                Spacer()
                framingHint
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("alleycat.scanner.cancelButton")
        }
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with kittylitter")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            stepRow(number: "1", title: "On the host you want to connect to, run:")
            commandRow
            stepRow(number: "2", title: "Point this camera at the QR code it prints.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.8)
        )
    }

    private func stepRow(number: String, title: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.black)
                .frame(width: 20, height: 20)
                .background(LitterTheme.accent, in: Circle())
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commandRow: some View {
        HStack(spacing: 10) {
            Text(Self.pairCommand)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.12))
                )
            Button(action: copyCommand) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("alleycat.scanner.copyCommandButton")
        }
        .padding(.leading, 30)
    }

    private var framingHint: some View {
        Text("Hold steady — the QR code is detected automatically.")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
    }

    private func copyCommand() {
        UIPasteboard.general.string = Self.pairCommand
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}

private struct QRCaptureSheet: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onCancel: () -> Void
    let onPermissionDenied: () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        controller.onCancel = onCancel
        controller.onPermissionDenied = onPermissionDenied
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let metadataQueue = DispatchQueue(label: "com.alleycat.qrscanner")
    private var didReportScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onPermissionDenied?()
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            onPermissionDenied?()
            return
        }
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        } else {
            onPermissionDenied?()
            return
        }

        let output = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: metadataQueue)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        } else {
            onPermissionDenied?()
            return
        }

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didReportScan else { return }
        guard let payload = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr })?
            .stringValue
        else { return }
        didReportScan = true
        DispatchQueue.main.async { [weak self] in
            self?.captureSession.stopRunning()
            self?.onScan?(payload)
        }
    }
}
