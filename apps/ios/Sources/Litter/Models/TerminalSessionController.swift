import Foundation
import Observation

@MainActor
@Observable
final class TerminalSessionController {
    enum Phase: Equatable {
        case idle
        case connecting
        case running
        case exited(Int32)
        case failed(String)
    }

    struct SshHostTrustChallenge {
        let host: String
        let port: UInt16
        let fingerprint: String
        let backend: TerminalBackendKind
        let isChanged: Bool
    }

    private(set) var phase: Phase = .idle
    private(set) var output = ""
    private(set) var sessionId: String?
    private(set) var sshTrustChallenge: SshHostTrustChallenge?

    @ObservationIgnored private let appStore: AppStore
    @ObservationIgnored private var outputListener: TerminalOutputRelay?
    @ObservationIgnored private var outputSink: ((Data) -> Void)?
    @ObservationIgnored private var eventGeneration = 0
    @ObservationIgnored private var terminalSize = TerminalSize(cols: 80, rows: 24)

    init() {
        self.appStore = AppModel.shared.store
    }

    init(appStore: AppStore) {
        self.appStore = appStore
    }

    var canSendInput: Bool {
        if case .running = phase { return true }
        return false
    }

    func openLocalIsh(cwd: String?) async {
        await open(backend: .localIsh(cwd: normalized(cwd)))
    }

    func open(backend: TerminalBackendKind) async {
        guard sessionId == nil else { return }
        eventGeneration &+= 1
        let generation = eventGeneration
        phase = .connecting
        sshTrustChallenge = nil
        do {
            let id: String
            if isSshBackend(backend) {
                let trustStore = TerminalSshTrustStore(backend: SwiftSshTrustBackend.shared)
                id = try await appStore.openTerminalSessionWithTrustStore(
                    kind: backend,
                    size: terminalSize,
                    trustStore: trustStore
                )
            } else {
                id = try await appStore.openTerminalSession(
                    kind: backend,
                    size: terminalSize
                )
            }
            sessionId = id
            appStore.setActiveTerminalId(id: id)
            guard let session = appStore.terminalSessionHandle(id: id) else {
                phase = .failed("Session disappeared after open")
                sessionId = nil
                return
            }
            let listener = TerminalOutputRelay(owner: self, generation: generation)
            listener.setOutputSink(outputSink)
            session.subscribeOutput(listener: listener)
            outputListener = listener
            phase = .running
        } catch {
            sessionId = nil
            if let challenge = Self.sshHostTrustChallenge(from: error, backend: backend) {
                sshTrustChallenge = challenge
                phase = .failed("Unknown SSH host key \(challenge.fingerprint)")
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func isSshBackend(_ backend: TerminalBackendKind) -> Bool {
        if case .remoteSsh = backend { return true }
        return false
    }

    func trustUnknownSshHostAndRetry() async {
        guard let challenge = sshTrustChallenge else { return }
        SwiftSshTrustBackend.shared.write(
            host: challenge.host,
            port: challenge.port,
            fingerprint: challenge.fingerprint
        )
        sshTrustChallenge = nil
        phase = .idle
        await open(backend: challenge.backend)
    }

    func dismissSshTrustChallenge() {
        sshTrustChallenge = nil
        phase = .idle
    }

    func switchBackend(_ backend: TerminalBackendKind) async {
        close()
        output = ""
        await open(backend: backend)
    }

    func send(_ string: String) async {
        await send(Data(string.utf8))
    }

    func send(_ data: Data) async {
        guard let id = sessionId, canSendInput else { return }
        guard let session = appStore.terminalSessionHandle(id: id) else { return }
        do {
            try await session.writeInput(data: data)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func sendLine(_ string: String) async {
        await send(string + "\n")
    }

    func clearOutput() {
        output = ""
    }

    func setOutputSink(_ sink: ((Data) -> Void)?) {
        outputSink = sink
        outputListener?.setOutputSink(sink)
    }

    private static func sshHostTrustChallenge(
        from error: Error,
        backend: TerminalBackendKind
    ) -> SshHostTrustChallenge? {
        guard case let .remoteSsh(
            host: host,
            port: port,
            username: _,
            auth: _,
            shell: _,
            acceptUnknownHost: _,
            cwd: _
        ) = backend else {
            return nil
        }
        let description = error.localizedDescription
        let isChanged = description.contains("host-key-changed:")
        guard let fingerprint = sshHostFingerprint(from: description) else {
            return nil
        }
        return SshHostTrustChallenge(
            host: host,
            port: port,
            fingerprint: fingerprint,
            backend: backend,
            isChanged: isChanged
        )
    }

    private static func sshHostFingerprint(from description: String) -> String? {
        guard let range = description.range(of: "unknown-host:") ?? description.range(of: "host-key-changed:") else { return nil }
        let raw = description[range.upperBound...]
        let fingerprint = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]"))
        return fingerprint.isEmpty ? nil : fingerprint
    }

    func resize(cols: UInt16, rows: UInt16, notifyBackend: Bool = true) async {
        guard cols > 0, rows > 0 else { return }
        let size = TerminalSize(cols: cols, rows: rows)
        terminalSize = size
        guard notifyBackend, let id = sessionId, canSendInput else { return }
        guard let session = appStore.terminalSessionHandle(id: id) else { return }
        do {
            try await session.resize(size: size)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func close() {
        eventGeneration &+= 1
        guard let id = sessionId else { return }
        sessionId = nil
        outputListener?.deactivate()
        outputListener = nil
        if appStore.activeTerminalId() == id {
            appStore.setActiveTerminalId(id: nil)
        }
        phase = .idle
        Task.detached(priority: .utility) { [appStore] in
            try? await appStore.closeTerminalSession(id: id)
        }
    }

    fileprivate func appendOutput(_ data: Data, generation: Int) {
        guard generation == eventGeneration else { return }
        if let outputSink {
            outputSink(data)
            return
        }
        output += String(decoding: data, as: UTF8.self)
        trimOutputIfNeeded()
    }

    fileprivate func markExited(_ code: Int32, generation: Int) {
        guard generation == eventGeneration else { return }
        phase = .exited(code)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func trimOutputIfNeeded() {
        let maxCount = 64_000
        guard output.count > maxCount else { return }
        output = String(output.suffix(maxCount))
    }
}

private final class TerminalOutputRelay: TerminalOutputListener, @unchecked Sendable {
    private weak var owner: TerminalSessionController?
    private let generation: Int
    private let lock = NSLock()
    private var outputSink: ((Data) -> Void)?
    private var active = true

    init(owner: TerminalSessionController, generation: Int) {
        self.owner = owner
        self.generation = generation
    }

    func setOutputSink(_ sink: ((Data) -> Void)?) {
        lock.lock()
        outputSink = sink
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        active = false
        outputSink = nil
        lock.unlock()
    }

    func onBytes(data: Data) {
        lock.lock()
        let isActive = active
        let sink = outputSink
        lock.unlock()

        guard isActive else { return }
        if let sink {
            sink(data)
            return
        }

        Task { @MainActor [weak owner, generation] in
            owner?.appendOutput(data, generation: generation)
        }
    }

    func onExit(code: Int32) {
        Task { @MainActor [weak owner, generation] in
            owner?.markExited(code, generation: generation)
        }
    }
}
