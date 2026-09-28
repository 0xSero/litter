import SwiftUI
import UIKit
import QuartzCore
import AudioToolbox

/// Swift facade over the Rust `TerminalRenderer`. The platform owns the
/// Ghostty surface (via `LitterGhosttyTerminal`); the renderer mediates the
/// non-UI-thread tick task, OSC parsing, selection plumbing, and bell
/// detection. This wrapper exists so SwiftUI consumers don't have to thread
/// UniFFI handles through every call.
@MainActor
final class GhosttyTerminalRenderer {
    var onInput: ((Data) -> Void)?
    var onNativeOutputVisibilityChanged: ((Bool) -> Void)?
    /// Fires on main when Rust pushes a new (or cleared) selection range.
    /// The host view uses this to repaint the selection-handle overlay.
    var onSelectionRangeChanged: ((TerminalCellRange?) -> Void)?
    /// Fires on main when the PTY stream emits a literal BEL. The host
    /// view drives haptic feedback from here.
    var onBell: (() -> Void)?

    private var terminal: LitterGhosttyTerminal?
    private var renderer: TerminalRenderer?
    private var backendBridge: GhosttyRendererBackendBridge?
    private var bellListener: TerminalRendererBellListener?
    private var pendingOutput: [Data] = []
    private var pendingWriteBuffer = Data()
    private var outputFlushScheduled = false
    private weak var attachedView: UIView?
    private var hasNativeVisibleOutput = false
    private var didSetConfigDir = false
    private var isInvalidated = false
    private var currentConfig: TerminalConfig?

    func attach(to view: UIView) {
        guard !isInvalidated else { return }
        guard terminal == nil else {
            attachedView = view
            resize(
                width: view.bounds.width,
                height: view.bounds.height,
                scale: view.window?.screen.scale ?? UIScreen.main.scale
            )
            return
        }

        attachedView = view
        do {
            let terminal = try LitterGhosttyTerminal(view: view)
            terminal.inputHandler = { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.onInput?(data)
                }
            }
            self.terminal = terminal
            let bridge = GhosttyRendererBackendBridge(terminal: terminal)
            bridge.onSelectionRangeChanged = { [weak self] range in
                self?.onSelectionRangeChanged?(range)
            }
            self.backendBridge = bridge
            let renderer = TerminalRenderer(backend: bridge)
            self.renderer = renderer
            let listener = TerminalRendererBellListener { [weak self] in
                Task { @MainActor [weak self] in
                    self?.onBell?()
                }
            }
            renderer.subscribeBell(listener: listener)
            self.bellListener = listener
            if let currentConfig {
                applyConfigToRenderer(currentConfig, renderer: renderer)
            }
            flushPendingOutput()
            updateNativeOutputVisibility(terminal: terminal)
        } catch {
            assertionFailure("Ghostty renderer failed: \(error.localizedDescription)")
        }
    }

    func resize(width: CGFloat, height: CGFloat, scale: CGFloat) {
        terminal?.resize(toWidth: width, height: height, scale: scale)
    }

    func setGridSize(cols: UInt16, rows: UInt16) {
        renderer?.setTerminalGridSize(cols: UInt32(cols), rows: UInt32(rows))
    }

    func write(_ data: Data) {
        guard !isInvalidated else { return }
        guard !data.isEmpty else { return }
        guard terminal != nil else {
            pendingOutput.append(data)
            if pendingOutput.count > 256 {
                pendingOutput.removeFirst(pendingOutput.count - 256)
            }
            return
        }
        // Tee bytes through the Rust OSC parser + bell detector before
        // handing them to Ghostty. `feed_output` runs the OSC state
        // machine and notifies any subscribed listeners (semantic state,
        // bell).
        enqueueOutput(data)
    }

    func makeOutputSink() -> (Data) -> Void {
        let batcher = GhosttyTerminalOutputBatcher { [weak self] data in
            self?.write(data)
        }
        return { data in
            batcher.append(data)
        }
    }

    func setOccluded(_ occluded: Bool) {
        renderer?.setOccluded(occluded: occluded)
    }

    func setFocused(_ focused: Bool) {
        renderer?.setFocused(focused: focused)
    }

    func sendKeyEvent(_ event: TerminalKeyEvent) {
        renderer?.sendKeyEvent(event: event)
    }

    func sendText(_ text: String, composing: Bool = false) {
        renderer?.sendText(text: text, composing: composing)
    }

    func sendPaste(_ text: String) {
        renderer?.sendPaste(text: text)
    }

    /// Send raw, unwrapped bytes straight to the PTY (used by accessory
    /// bar control keys so Esc/Tab/Ctrl-C don't accidentally enter
    /// bracketed-paste mode).
    func sendRawBytes(_ data: Data) {
        renderer?.sendRawBytes(bytes: data)
    }

    /// Send `selection` to the assistant on `threadKey`. Pulls cwd + last
    /// shell command from the renderer's OSC semantic state.
    func sendTextToAssistant(
        store: AppStore,
        threadKey: ThreadKey,
        selection: String
    ) async throws {
        guard let renderer else { return }
        try await renderer.sendTextToAssistant(
            store: store,
            payload: TerminalSendToAssistantPayload(
                threadKey: threadKey,
                includeCwd: true,
                includeLastCommand: true
            ),
            selection: selection
        )
    }

    var mouseCaptured: Bool {
        terminal?.mouseCaptured() ?? false
    }

    func sendMousePos(x: Double, y: Double, mods: Int32 = 0) {
        terminal?.mousePosX(x, y: y, mods: mods)
    }

    @discardableResult
    func sendMouseButton(pressed: Bool, button: Int32, mods: Int32 = 0) -> Bool {
        terminal?.mouseButtonPressed(pressed, button: button, mods: mods) ?? false
    }

    func sendMouseScroll(x: Double, y: Double, precise: Bool, mods: Int32 = 0) {
        terminal?.mouseScrollX(x, y: y, precise: precise, mods: mods)
    }

    func applyConfig(_ config: TerminalConfig) {
        currentConfig = config
        guard let renderer else { return }
        applyConfigToRenderer(config, renderer: renderer)
    }

    private func applyConfigToRenderer(_ config: TerminalConfig, renderer: TerminalRenderer) {
        if !didSetConfigDir {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            if let dir = cachesDir?.appendingPathComponent("litter/terminal", isDirectory: true) {
                renderer.setConfigDir(path: dir.path)
                didSetConfigDir = true
            }
        }
        do {
            try renderer.applyConfig(config: config)
            if let view = attachedView {
                resize(
                    width: view.bounds.width,
                    height: view.bounds.height,
                    scale: view.window?.screen.scale ?? UIScreen.main.scale
                )
            }
        } catch {
            // Surface lifecycle race or invalid path; let user retry from sheet.
        }
    }

    // MARK: - Selection bridge

    func hitTest(x: CGFloat, y: CGFloat) -> TerminalCellPosition? {
        renderer?.hitTest(xPx: Float(x), yPx: Float(y))
    }

    func wordRange(at pos: TerminalCellPosition) -> TerminalCellRange? {
        renderer?.wordRangeAt(pos: pos)
    }

    func lineRange(at pos: TerminalCellPosition) -> TerminalCellRange? {
        renderer?.lineRangeAt(pos: pos)
    }

    func selectionSet(_ range: TerminalCellRange) {
        renderer?.selectionSet(range: range)
    }

    func selectionClear() {
        renderer?.selectionClear()
    }

    @discardableResult
    func selectionAll() -> TerminalCellRange? {
        renderer?.selectionAll()
    }

    func readSelection() -> String? {
        renderer?.readSelection()
    }

    func currentSelectionRange() -> TerminalCellRange? {
        backendBridge?.currentSelectionRange()
    }

    func cellMetrics() -> TerminalCellMetrics? {
        renderer?.cellMetrics()
    }

    func surfaceMetrics() -> LitterGhosttySurfaceMetrics? {
        guard let terminal else { return nil }
        let metrics = terminal.surfaceMetrics()
        guard metrics.cellWidthPx > 0, metrics.cellHeightPx > 0 else { return nil }
        return metrics
    }

    func linkAtPoint(x: CGFloat, y: CGFloat) -> TerminalLink? {
        renderer?.linkAtPoint(xPx: Float(x), yPx: Float(y))
    }

    /// Feed the renderer the most recent viewport rows so plain-text URL
    /// detection has fresh content. The host view calls this on a
    /// debounce after writes.
    func updateViewportLinks() {
        guard let renderer, let terminal else { return }
        let text = terminal.visibleText()
        if text.isEmpty { return }
        let rows: [String] = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        renderer.setViewportText(startRow: 0, rows: rows)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        onInput = nil
        onNativeOutputVisibilityChanged = nil
        onSelectionRangeChanged = nil
        onBell = nil
        renderer?.detach()
        renderer = nil
        backendBridge = nil
        bellListener = nil
        terminal?.invalidate()
        terminal = nil
        attachedView = nil
        pendingOutput.removeAll()
        pendingWriteBuffer.removeAll(keepingCapacity: false)
        outputFlushScheduled = false
        didSetConfigDir = false
        setNativeOutputVisible(false)
    }

    func clearScreen() {
        guard let terminal else {
            pendingOutput.removeAll()
            setNativeOutputVisible(false)
            return
        }
        terminal.writeOutput(Data([0x1B, 0x63]))
        pendingWriteBuffer.removeAll(keepingCapacity: true)
        outputFlushScheduled = false
        setNativeOutputVisible(false)
    }

    private func flushPendingOutput() {
        guard !isInvalidated else { return }
        guard let terminal else { return }
        for data in pendingOutput {
            enqueueOutput(data)
        }
        pendingOutput.removeAll()
        flushOutputBuffer()
        updateNativeOutputVisibility(terminal: terminal)
    }

    private func enqueueOutput(_ data: Data) {
        guard !isInvalidated else { return }
        pendingWriteBuffer.append(data)
        scheduleOutputFlush()
    }

    private func scheduleOutputFlush() {
        guard !outputFlushScheduled else { return }
        outputFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            self?.flushOutputBuffer()
        }
    }

    private func flushOutputBuffer() {
        outputFlushScheduled = false
        guard !isInvalidated else {
            pendingWriteBuffer.removeAll(keepingCapacity: false)
            return
        }
        guard !pendingWriteBuffer.isEmpty else { return }
        guard let terminal else {
            pendingOutput.append(pendingWriteBuffer)
            pendingWriteBuffer.removeAll(keepingCapacity: true)
            return
        }

        let data = pendingWriteBuffer
        pendingWriteBuffer.removeAll(keepingCapacity: true)
        renderer?.feedOutput(bytes: data)
        terminal.writeOutput(data)
        updateNativeOutputVisibility(terminal: terminal)
    }

    private func updateNativeOutputVisibility(terminal: LitterGhosttyTerminal) {
        guard !hasNativeVisibleOutput else { return }
        let text = terminal.visibleText()
        if text.contains(where: { !$0.isWhitespace }) {
            setNativeOutputVisible(true)
        }
    }

    private func setNativeOutputVisible(_ value: Bool) {
        guard hasNativeVisibleOutput != value else { return }
        hasNativeVisibleOutput = value
        onNativeOutputVisibilityChanged?(value)
    }
}

private final class GhosttyTerminalOutputBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var scheduled = false
    private let flush: @MainActor (Data) -> Void

    init(flush: @escaping @MainActor (Data) -> Void) {
        self.flush = flush
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        var shouldSchedule = false
        lock.lock()
        buffer.append(data)
        if !scheduled {
            scheduled = true
            shouldSchedule = true
        }
        lock.unlock()

        if shouldSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
                self?.flushNow()
            }
        }
    }

    private func flushNow() {
        lock.lock()
        let data = buffer
        buffer.removeAll(keepingCapacity: true)
        scheduled = false
        lock.unlock()

        guard !data.isEmpty else { return }
        Task { @MainActor [flush] in
            flush(data)
        }
    }
}

/// Closure-backed adapter implementing the Rust `TerminalBellListener`
/// callback interface. Rust holds an `Arc` to the listener for as long
/// as it's subscribed; we keep a strong reference from the renderer so it
/// outlives the renderer itself.
private final class TerminalRendererBellListener: TerminalBellListener, @unchecked Sendable {
    private let block: () -> Void

    init(_ block: @escaping () -> Void) {
        self.block = block
    }

    func onBell() {
        block()
    }
}

// MARK: - SwiftUI bridge

struct GhosttyTerminalView: UIViewRepresentable {
    let renderer: GhosttyTerminalRenderer
    let onNativeOutputVisibilityChanged: (Bool) -> Void
    let onInput: (Data) -> Void
    /// Tapped Clear in the accessory bar.
    var onClearTapped: (() -> Void)?
    /// Tapped "Send to AI" in the accessory bar.
    var onSendToAssistant: (() -> Void)?
    /// Pinch ended at this point size (clamped 10–24). The owner persists
    /// it back and re-applies the config so the terminal re-grids.
    var onFontSizePinched: ((Double) -> Void)?
    /// Initial font size for the pinch base. Re-read on every update so
    /// the SwiftUI source-of-truth and the host view stay in lockstep.
    var fontSize: Double = 13.0

    func makeUIView(context: Context) -> GhosttyHostView {
        let view = GhosttyHostView()
        view.backgroundColor = .black
        view.isOpaque = true
        view.renderer = renderer
        view.onClearTapped = onClearTapped
        view.onSendToAssistant = onSendToAssistant
        view.onFontSizePinched = onFontSizePinched
        view.currentFontSize = fontSize
        renderer.onInput = onInput
        renderer.onNativeOutputVisibilityChanged = onNativeOutputVisibilityChanged
        renderer.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: GhosttyHostView, context: Context) {
        renderer.onInput = onInput
        renderer.onNativeOutputVisibilityChanged = onNativeOutputVisibilityChanged
        uiView.renderer = renderer
        uiView.onClearTapped = onClearTapped
        uiView.onSendToAssistant = onSendToAssistant
        uiView.onFontSizePinched = onFontSizePinched
        uiView.currentFontSize = fontSize
        renderer.resize(
            width: uiView.bounds.width,
            height: uiView.bounds.height,
            scale: uiView.window?.screen.scale ?? UIScreen.main.scale
        )
    }

    static func dismantleUIView(_ uiView: GhosttyHostView, coordinator: ()) {
        let renderer = uiView.renderer
        uiView.teardownForDismissal()
        uiView.renderer = nil
        renderer?.invalidate()
    }
}

// MARK: - Hidden first-responder + accessory bar

/// Invisible first-responder overlaid on the Ghostty surface. We use a
/// bare `UIView` (not `UITextField`) because UITextField routes the
/// software keyboard through the `UITextInput` pipeline
/// (`replaceRange:withText:`, marked-text APIs, etc.), and overrides of
/// `insertText:` on UITextField are not invoked for every keystroke.
/// `UIView + UIKeyInput` guarantees the system calls `insertText:` /
/// `deleteBackward` for every character so we can forward each one to
/// Ghostty's encoder.
///
/// We also own the input accessory view so the row of Esc/Tab/Ctrl-…
/// keys floats above the system keyboard automatically.
final class LitterGhosttyInputView: UIView, UIKeyInput, UITextInputTraits {
    weak var renderer: GhosttyTerminalRenderer?

    // UITextInputTraits — terminal input is verbatim, no IME assistance.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default

    /// Custom accessory bar. Setting this swaps the docked input
    /// accessory view above the keyboard.
    var accessoryBar: LitterTerminalAccessoryBar? {
        didSet {
            // If the keyboard is already up, ask UIKit to swap the
            // accessory in-place.
            if isFirstResponder {
                reloadInputViews()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isOpaque = false
        backgroundColor = .clear
        tintColor = .clear
        clipsToBounds = true
        accessibilityLabel = "Terminal input"
    }

    // MARK: - UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        sendCommittedText(text)
    }

    func deleteBackward() {
        sendRawBytes([0x7F])
    }

    override var canBecomeFirstResponder: Bool { true }

    override var inputAccessoryView: UIView? { accessoryBar }

    /// Touches must reach the host view's gesture recognizers (tap to
    /// focus keyboard, long-press to select, scroll pan, pinch). Drop the
    /// overlay out of hit-testing entirely so it never swallows touches
    /// even though it covers the full host area.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if let raw = Self.rawBytes(for: key) {
                renderer?.sendRawBytes(raw)
                handled = true
                continue
            }
            if let event = Self.terminalEvent(for: key, action: .press, repeated: false) {
                renderer?.sendKeyEvent(event)
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    private func sendCommittedText(_ text: String) {
        guard !text.isEmpty else { return }
        // UIKeyInput delivers Return as "\n", but PTYs expect carriage
        // return for Enter. Keep other committed text byte-for-byte.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r")
        guard let data = normalized.data(using: .utf8), !data.isEmpty else { return }
        renderer?.sendRawBytes(data)
    }

    private func sendRawBytes(_ bytes: [UInt8]) {
        renderer?.sendRawBytes(Data(bytes))
    }

    private static func rawBytes(for key: UIKey) -> Data? {
        if key.modifierFlags.contains(.control),
           let scalar = key.charactersIgnoringModifiers.lowercased().unicodeScalars.first,
           scalar.value >= 97,
           scalar.value <= 122 {
            return Data([UInt8(scalar.value - 96)])
        }

        switch key.keyCode {
        case .keyboardReturnOrEnter: return Data([0x0D])
        case .keyboardTab: return Data([0x09])
        case .keyboardDeleteOrBackspace: return Data([0x7F])
        case .keyboardEscape: return Data([0x1B])
        case .keyboardSpacebar where key.modifierFlags.contains(.control): return Data([0x00])
        case .keyboardUpArrow: return Data([0x1B, 0x5B, 0x41])
        case .keyboardDownArrow: return Data([0x1B, 0x5B, 0x42])
        case .keyboardRightArrow: return Data([0x1B, 0x5B, 0x43])
        case .keyboardLeftArrow: return Data([0x1B, 0x5B, 0x44])
        case .keyboardHome: return Data([0x1B, 0x5B, 0x48])
        case .keyboardEnd: return Data([0x1B, 0x5B, 0x46])
        case .keyboardPageUp: return Data([0x1B, 0x5B, 0x35, 0x7E])
        case .keyboardPageDown: return Data([0x1B, 0x5B, 0x36, 0x7E])
        case .keyboardDeleteForward: return Data([0x1B, 0x5B, 0x33, 0x7E])
        case .keyboardInsert: return Data([0x1B, 0x5B, 0x32, 0x7E])
        default: return nil
        }
    }

    private static func terminalEvent(
        for key: UIKey,
        action: TerminalKeyAction,
        repeated: Bool
    ) -> TerminalKeyEvent? {
        let code = mapHIDUsage(key.keyCode)
        // Only forward keys we have a code for; printable characters arrive
        // separately via `insertText` so the IME decision (e.g. dead keys)
        // stays in UIKit.
        if code == .unidentified { return nil }
        let mods = TerminalKeyMods(
            shift: key.modifierFlags.contains(.shift),
            ctrl: key.modifierFlags.contains(.control),
            alt: key.modifierFlags.contains(.alternate),
            meta: key.modifierFlags.contains(.command)
        )
        return TerminalKeyEvent(
            action: action,
            code: code,
            mods: mods,
            text: key.characters,
            repeat: repeated
        )
    }

    private static func mapHIDUsage(_ keyCode: UIKeyboardHIDUsage) -> TerminalKeyCode {
        switch keyCode {
        case .keyboardReturnOrEnter: return .enter
        case .keyboardTab: return .tab
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardEscape: return .escape
        case .keyboardSpacebar: return .space
        case .keyboardUpArrow: return .arrowUp
        case .keyboardDownArrow: return .arrowDown
        case .keyboardLeftArrow: return .arrowLeft
        case .keyboardRightArrow: return .arrowRight
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardDeleteForward: return .delete
        case .keyboardInsert: return .insert
        case .keyboardF1: return .f1
        case .keyboardF2: return .f2
        case .keyboardF3: return .f3
        case .keyboardF4: return .f4
        case .keyboardF5: return .f5
        case .keyboardF6: return .f6
        case .keyboardF7: return .f7
        case .keyboardF8: return .f8
        case .keyboardF9: return .f9
        case .keyboardF10: return .f10
        case .keyboardF11: return .f11
        case .keyboardF12: return .f12
        default: return .unidentified
        }
    }
}

/// Compact row of common terminal keys docked above the system keyboard.
/// Each chip sends a fixed escape sequence (or fires a callback) so the
/// user doesn't need to know how to escape control chars from the IME.
final class LitterTerminalAccessoryBar: UIView {
    /// Send a raw UTF-8 string straight to the PTY (Esc/Tab/Ctrl-C, etc).
    var onSendRaw: ((String) -> Void)?
    /// Paste the current `UIPasteboard.string` (bracket-pasted by Rust).
    var onPaste: (() -> Void)?
    /// Wipe local scrollback + screen.
    var onClear: (() -> Void)?
    /// Forward selected output to the assistant thread.
    var onSendToAssistant: (() -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    /// Buttons that need to enable/disable based on pasteboard state.
    private weak var pasteButton: UIButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
        rebuildKeys()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
        rebuildKeys()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    private func configure() {
        backgroundColor = UIColor.black.withAlphaComponent(0.96)
        translatesAutoresizingMaskIntoConstraints = false
        autoresizingMask = [.flexibleWidth]
        frame = CGRect(x: 0, y: 0, width: 320, height: 44)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let topHairline = UIView()
        topHairline.translatesAutoresizingMaskIntoConstraints = false
        topHairline.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        addSubview(topHairline)
        NSLayoutConstraint.activate([
            topHairline.topAnchor.constraint(equalTo: topAnchor),
            topHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            topHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            topHairline.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteboardChanged),
            name: UIPasteboard.changedNotification,
            object: nil
        )
    }

    private func rebuildKeys() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addRawKey(title: "Esc", payload: "\u{1B}")
        addRawKey(title: "Tab", payload: "\t")
        addRawKey(title: "Ctrl-C", payload: "\u{03}")
        addRawKey(title: "Ctrl-D", payload: "\u{04}")
        addRawKey(title: "Ctrl-Z", payload: "\u{1A}")
        addRawKey(title: "↑", payload: "\u{1B}[A")
        addRawKey(title: "↓", payload: "\u{1B}[B")
        addRawKey(title: "←", payload: "\u{1B}[D")
        addRawKey(title: "→", payload: "\u{1B}[C")
        pasteButton = addActionKey(title: "Paste") { [weak self] in
            self?.onPaste?()
        }
        updatePasteState()
        _ = addActionKey(title: "Clear") { [weak self] in
            self?.onClear?()
        }
        _ = addActionKey(title: "Send to AI") { [weak self] in
            self?.onSendToAssistant?()
        }
    }

    private func addRawKey(title: String, payload: String) {
        let button = makeKey(title: title)
        button.addAction(UIAction { [weak self] _ in
            self?.onSendRaw?(payload)
        }, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }

    @discardableResult
    private func addActionKey(title: String, action: @escaping () -> Void) -> UIButton {
        let button = makeKey(title: title)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        stack.addArrangedSubview(button)
        return button
    }

    private func makeKey(title: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.baseForegroundColor = .white.withAlphaComponent(0.86)
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.10)
        config.background.cornerRadius = 8
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var out = attrs
            out.font = UIFont(name: "SFMono-Regular", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            return out
        }
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    @objc private func pasteboardChanged() {
        updatePasteState()
    }

    private func updatePasteState() {
        guard let button = pasteButton else { return }
        button.isEnabled = UIPasteboard.general.hasStrings
        button.alpha = button.isEnabled ? 1.0 : 0.45
    }
}

// MARK: - Selection overlay

/// Painted selection state: a highlight rectangle per row of the range,
/// plus circular drag handles at the start/end cell corners. Ghostty
/// doesn't paint our long-press selection itself; we draw it on top of
/// the Metal surface using cell metrics returned by the renderer.
final class TerminalSelectionOverlayView: UIView {
    private static let handleRadius: CGFloat = 7.0
    private static let handleHitRadius: CGFloat = 28.0
    private static let highlightInsetRatio: CGFloat = 0.06

    enum Handle: Equatable {
        case start
        case end
    }

    /// Range + metrics used to paint. Both must be set for anything to
    /// draw; clearing either erases the overlay.
    var range: TerminalCellRange? {
        didSet {
            guard oldValue != range else { return }
            setNeedsDisplay()
        }
    }

    var metrics: TerminalCellMetrics? {
        didSet { setNeedsDisplay() }
    }

    /// Called as the user drags a handle. The host view extends the
    /// selection range accordingly.
    var onHandleDrag: ((Handle, CGPoint, UIGestureRecognizer.State) -> Void)?

    private let handlePan = UIPanGestureRecognizer()
    private var activeHandle: Handle?
    private var contentScale: CGFloat = UIScreen.main.scale

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func setContentScale(_ scale: CGFloat) {
        contentScale = max(scale, 1.0)
        setNeedsDisplay()
    }

    private func configure() {
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = true
        handlePan.addTarget(self, action: #selector(handlePanGesture(_:)))
        addGestureRecognizer(handlePan)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Only swallow touches that land on a handle; everything else
        // falls through to the underlying terminal so taps, long-presses,
        // and scroll pans still hit it.
        handle(at: point) != nil
    }

    /// Convert the overlay's points to viewport pixel space (matches the
    /// coords stored in `TerminalCellMetrics`).
    private func cellRectInPoints(row: UInt32, startCol: UInt32, endCol: UInt32) -> CGRect? {
        guard let metrics else { return nil }
        guard contentScale > 0 else { return nil }
        let cellWidthPt = CGFloat(metrics.cellWidthPx) / contentScale
        let cellHeightPt = CGFloat(metrics.cellHeightPx) / contentScale
        let firstCol = CGFloat(startCol)
        let lastColInclusive = CGFloat(endCol)
        let width = (lastColInclusive - firstCol + 1) * cellWidthPt
        let rect = CGRect(
            x: firstCol * cellWidthPt,
            y: CGFloat(row) * cellHeightPt,
            width: width,
            height: cellHeightPt
        )
        return rect.insetBy(dx: 0, dy: max(1, cellHeightPt * Self.highlightInsetRatio))
    }

    override func draw(_ rect: CGRect) {
        guard let range, let metrics, metrics.cols > 0 else { return }
        let normalized = normalizedRange(range)
        UIColor.systemBlue.withAlphaComponent(0.30).setFill()
        let lastCol = metrics.cols > 0 ? metrics.cols - 1 : 0
        for row in normalized.start.row...normalized.end.row {
            let firstCol = row == normalized.start.row ? normalized.start.col : 0
            let endCol = row == normalized.end.row ? normalized.end.col : lastCol
            guard endCol >= firstCol else { continue }
            if let cellRect = cellRectInPoints(row: row, startCol: firstCol, endCol: endCol) {
                UIBezierPath(roundedRect: cellRect, cornerRadius: 2).fill()
            }
        }
        drawHandles(for: normalized)
    }

    /// Union rect of all selection rows in the overlay's coordinate space.
    /// Used by the edit menu to anchor itself above the selected text.
    func selectionUnionRect() -> CGRect? {
        guard let range, let metrics, metrics.cols > 0 else { return nil }
        let normalized = normalizedRange(range)
        let lastCol = metrics.cols > 0 ? metrics.cols - 1 : 0
        var union: CGRect = .null
        for row in normalized.start.row...normalized.end.row {
            let firstCol = row == normalized.start.row ? normalized.start.col : 0
            let endCol = row == normalized.end.row ? normalized.end.col : lastCol
            guard endCol >= firstCol else { continue }
            if let cellRect = cellRectInPoints(row: row, startCol: firstCol, endCol: endCol) {
                union = union.union(cellRect)
            }
        }
        if union.isNull { return nil }
        return union.insetBy(dx: 0, dy: -6)
    }

    private func drawHandles(for range: TerminalCellRange) {
        guard let metrics, metrics.cellWidthPx > 0, metrics.cellHeightPx > 0 else { return }
        let radius = Self.handleRadius
        let centers = handleCenters(for: range, metrics: metrics)
        UIColor.systemBlue.setFill()
        UIBezierPath(
            ovalIn: CGRect(
                x: centers.start.x - radius,
                y: centers.start.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        ).fill()
        UIBezierPath(
            ovalIn: CGRect(
                x: centers.end.x - radius,
                y: centers.end.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        ).fill()
    }

    private func handleCenters(for range: TerminalCellRange, metrics: TerminalCellMetrics)
        -> (start: CGPoint, end: CGPoint)
    {
        let cellWidthPt = CGFloat(metrics.cellWidthPx) / contentScale
        let cellHeightPt = CGFloat(metrics.cellHeightPx) / contentScale
        let start = CGPoint(
            x: CGFloat(range.start.col) * cellWidthPt,
            y: CGFloat(range.start.row + 1) * cellHeightPt
        )
        let end = CGPoint(
            x: CGFloat(range.end.col + 1) * cellWidthPt,
            y: CGFloat(range.end.row + 1) * cellHeightPt
        )
        return (clampCenter(start), clampCenter(end))
    }

    private func clampCenter(_ point: CGPoint) -> CGPoint {
        let radius = Self.handleRadius
        let maxX = max(radius, bounds.width - radius)
        let maxY = max(radius, bounds.height - radius)
        return CGPoint(
            x: min(max(point.x, radius), maxX),
            y: min(max(point.y, radius), maxY)
        )
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            activeHandle = handle(at: location)
            if let activeHandle {
                onHandleDrag?(activeHandle, location, .began)
            }
        case .changed, .ended, .cancelled, .failed:
            guard let activeHandle else { return }
            onHandleDrag?(activeHandle, location, gesture.state)
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                self.activeHandle = nil
            }
        default:
            break
        }
    }

    private func handle(at point: CGPoint) -> Handle? {
        guard let range, let metrics else { return nil }
        let centers = handleCenters(for: normalizedRange(range), metrics: metrics)
        let dStart = hypot(point.x - centers.start.x, point.y - centers.start.y)
        let dEnd = hypot(point.x - centers.end.x, point.y - centers.end.y)
        let hit = Self.handleHitRadius
        switch (dStart <= hit, dEnd <= hit) {
        case (true, true):
            return dStart <= dEnd ? .start : .end
        case (true, false):
            return .start
        case (false, true):
            return .end
        default:
            return nil
        }
    }

    /// Sort start ≤ end so painting and handle placement are direction-
    /// agnostic. The caller is allowed to push an "inverted" range when
    /// the user drags right-to-left.
    private func normalizedRange(_ range: TerminalCellRange) -> TerminalCellRange {
        let startBeforeEnd =
            range.start.row < range.end.row ||
            (range.start.row == range.end.row && range.start.col <= range.end.col)
        if startBeforeEnd { return range }
        return TerminalCellRange(start: range.end, end: range.start, rectangle: range.rectangle)
    }
}

// MARK: - Host view

/// Terminal canvas. Hosts the Metal-backed Ghostty surface, the
/// selection-handle overlay, and the hidden first-responder text field
/// that owns the keyboard + accessory bar. Coordinates every gesture the
/// touch UX needs: long-press to select, drag handles to extend, tap to
/// focus keyboard / open links, pinch to resize, two-finger pan to
/// scroll, and one-finger pan when an in-terminal mouse-tracking app
/// captures the mouse.
final class GhosttyHostView: UIView, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    private static let bellHapticThrottle: TimeInterval = 0.25

    weak var renderer: GhosttyTerminalRenderer? {
        didSet {
            keyboardOverlay.renderer = renderer
            attachRendererCallbacks()
        }
    }

    /// Tapped Clear in the accessory bar.
    var onClearTapped: (() -> Void)?
    /// Tapped Send-to-AI in the accessory bar.
    var onSendToAssistant: (() -> Void)?
    /// Pinch ended at this point size.
    var onFontSizePinched: ((Double) -> Void)?

    /// The owner's authoritative font size; we apply pinch deltas against
    /// this so the gesture is stable across multiple pinches in a row.
    var currentFontSize: Double = 13.0

    private var scrollPan: UIPanGestureRecognizer?
    private var dragPan: UIPanGestureRecognizer?
    private var longPress: UILongPressGestureRecognizer?
    private var pinch: UIPinchGestureRecognizer?
    private var tap: UITapGestureRecognizer?
    private var lastScrollTranslation: CGPoint = .zero
    private var dragInProgress = false
    private var selectionDragInProgress = false
    private var selectionAnchorPos: TerminalCellPosition?
    private var pinchStartFontSize: Double = 13.0
    private var lastBellTimestamp: TimeInterval = 0
    private var keyboardIsVisible = false
    private var isDismantled = false

    private let keyboardOverlay = LitterGhosttyInputView()
    private let accessoryBar = LitterTerminalAccessoryBar()
    private let selectionOverlay = TerminalSelectionOverlayView()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)

    override class var layerClass: AnyClass { CAMetalLayer.self }

    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        installSubviews()
        installGestureRecognizers()
        installAccessoryActions()
        addInteraction(editMenu)
        addKeyboardObservers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installSubviews()
        installGestureRecognizers()
        installAccessoryActions()
        addInteraction(editMenu)
        addKeyboardObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func installSubviews() {
        keyboardOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardOverlay)
        NSLayoutConstraint.activate([
            keyboardOverlay.topAnchor.constraint(equalTo: topAnchor, constant: -9999),
            keyboardOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -9999),
            keyboardOverlay.widthAnchor.constraint(equalToConstant: 1),
            keyboardOverlay.heightAnchor.constraint(equalToConstant: 1),
        ])
        // The input view only needs to be in the responder chain. Keeping
        // it tiny and far offscreen prevents UIKit's text input adornments
        // from drawing a caret over the terminal surface.
        keyboardOverlay.accessoryBar = accessoryBar

        selectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionOverlay)
        NSLayoutConstraint.activate([
            selectionOverlay.topAnchor.constraint(equalTo: topAnchor),
            selectionOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        selectionOverlay.onHandleDrag = { [weak self] handle, location, state in
            self?.handleSelectionHandleDrag(handle: handle, location: location, state: state)
        }
    }

    private func installAccessoryActions() {
        accessoryBar.onSendRaw = { [weak self] payload in
            guard let renderer = self?.renderer else { return }
            // Raw control sequences (Esc, Tab, Ctrl-C, arrows) go straight
            // to the PTY input direction without the bracketed-paste
            // wrapper. iSH / busybox shells don't enable paste mode by
            // default, so the wrapper would print as literal text and
            // break the keystroke.
            if let data = payload.data(using: .utf8) {
                renderer.sendRawBytes(data)
            }
        }
        accessoryBar.onPaste = { [weak self] in
            guard let renderer = self?.renderer else { return }
            if let text = UIPasteboard.general.string {
                renderer.sendPaste(text)
            }
        }
        accessoryBar.onClear = { [weak self] in
            self?.onClearTapped?()
        }
        accessoryBar.onSendToAssistant = { [weak self] in
            self?.onSendToAssistant?()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let hostResult = super.becomeFirstResponder()
        let inputResult = focusTerminalInput()
        return hostResult || inputResult
    }

    private func installGestureRecognizers() {
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scroll.minimumNumberOfTouches = 1
        scroll.maximumNumberOfTouches = 2
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        addGestureRecognizer(scroll)
        scrollPan = scroll

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDragPan(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        drag.cancelsTouchesInView = false
        drag.delegate = self
        addGestureRecognizer(drag)
        dragPan = drag

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        self.tap = tap

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.32
        longPress.allowableMovement = 12
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        addGestureRecognizer(longPress)
        self.longPress = longPress

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)
        self.pinch = pinch
    }

    private func addKeyboardObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    // MARK: - Renderer wiring

    private func attachRendererCallbacks() {
        guard let renderer else { return }
        renderer.onSelectionRangeChanged = { [weak self] range in
            self?.selectionOverlay.range = range
            self?.selectionOverlay.metrics = self?.renderer?.cellMetrics()
        }
        renderer.onBell = { [weak self] in
            self?.fireBellHaptic()
        }
    }

    private func fireBellHaptic() {
        let now = CACurrentMediaTime()
        if now - lastBellTimestamp < Self.bellHapticThrottle { return }
        lastBellTimestamp = now
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        // Audible bell when system sound is enabled; respects the silent
        // switch via AudioServices.
        AudioServicesPlaySystemSound(1057)
    }

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // If a selection exists, a tap dismisses it. Otherwise check for
        // a tappable hyperlink under the touch point; absent that, focus
        // the keyboard.
        if renderer?.currentSelectionRange() != nil {
            renderer?.selectionClear()
            return
        }
        let location = gesture.location(in: self)
        if let link = linkAtPoint(viewPoint: location), let url = URL(string: link.url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }
        focusTerminalInput(forceRefresh: true)
    }

    private func linkAtPoint(viewPoint: CGPoint) -> TerminalLink? {
        renderer?.updateViewportLinks()
        let scale = contentScale
        return renderer?.linkAtPoint(x: viewPoint.x * scale, y: viewPoint.y * scale)
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let renderer else { return }
        // While selecting (long-press), the scroll pan stays disabled so
        // the user's drag extends the selection instead.
        if selectionDragInProgress { return }
        if renderer.mouseCaptured && gesture.numberOfTouches == 1 { return }
        switch gesture.state {
        case .began:
            lastScrollTranslation = .zero
        case .changed:
            let translation = gesture.translation(in: self)
            let dx = Double(translation.x - lastScrollTranslation.x)
            let dy = Double(translation.y - lastScrollTranslation.y)
            lastScrollTranslation = translation
            renderer.sendMouseScroll(x: dx, y: dy, precise: true)
        case .ended, .cancelled, .failed:
            lastScrollTranslation = .zero
        default:
            break
        }
    }

    @objc private func handleDragPan(_ gesture: UIPanGestureRecognizer) {
        guard let renderer, renderer.mouseCaptured else {
            if dragInProgress {
                renderer?.sendMouseButton(pressed: false, button: 1)
                dragInProgress = false
            }
            return
        }
        let scale = contentScale
        let location = gesture.location(in: self)
        let px = Double(location.x * scale)
        let py = Double(location.y * scale)
        switch gesture.state {
        case .began:
            renderer.sendMousePos(x: px, y: py)
            renderer.sendMouseButton(pressed: true, button: 1)
            dragInProgress = true
        case .changed:
            renderer.sendMousePos(x: px, y: py)
        case .ended, .cancelled, .failed:
            renderer.sendMouseButton(pressed: false, button: 1)
            dragInProgress = false
        default:
            break
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let renderer else { return }
        let location = gesture.location(in: self)
        let scale = contentScale
        switch gesture.state {
        case .began:
            // Pick the cell under the finger; seed word selection.
            guard let pos = renderer.hitTest(x: location.x * scale, y: location.y * scale) else { return }
            selectionAnchorPos = pos
            selectionDragInProgress = true
            let initial = renderer.wordRange(at: pos)
                ?? TerminalCellRange(start: pos, end: pos, rectangle: false)
            renderer.selectionSet(initial)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            guard let anchor = selectionAnchorPos,
                  let focus = renderer.hitTest(x: location.x * scale, y: location.y * scale) else {
                return
            }
            renderer.selectionSet(
                TerminalCellRange(start: anchor, end: focus, rectangle: false)
            )
        case .ended, .cancelled, .failed:
            selectionDragInProgress = false
            // Present the edit menu over the final selection rect on a
            // run-loop tick so the long-press recognizer fully transitions
            // and we don't fight UIKit for the responder.
            DispatchQueue.main.async { [weak self] in
                self?.presentEditMenu()
            }
        default:
            break
        }
    }

    /// Handle a drag of an existing selection handle. Rotates the anchor
    /// to the *opposite* end so the handle the user is pulling stays
    /// glued to their finger.
    private func handleSelectionHandleDrag(
        handle: TerminalSelectionOverlayView.Handle,
        location: CGPoint,
        state: UIGestureRecognizer.State
    ) {
        guard let renderer, let range = renderer.currentSelectionRange() else { return }
        let scale = contentScale
        let viewPx = CGPoint(x: location.x * scale, y: location.y * scale)
        guard let focus = renderer.hitTest(x: viewPx.x, y: viewPx.y) else { return }
        switch state {
        case .began:
            selectionDragInProgress = true
            selectionAnchorPos = handle == .start ? range.end : range.start
        case .changed:
            guard let anchor = selectionAnchorPos else { return }
            renderer.selectionSet(
                TerminalCellRange(start: anchor, end: focus, rectangle: false)
            )
        case .ended, .cancelled, .failed:
            selectionDragInProgress = false
            DispatchQueue.main.async { [weak self] in
                self?.presentEditMenu()
            }
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartFontSize = currentFontSize
        case .changed:
            // Smooth: scale font size by the current pinch scale,
            // clamped to a humane range. We don't push it back to the
            // SwiftUI state until the gesture settles to avoid storming
            // applyConfig on every callback.
            let scaled = pinchStartFontSize * Double(gesture.scale)
            let clamped = min(max(scaled, 10.0), 24.0)
            // Live preview: bump local font size on the receiver so the
            // next layoutSubviews picks up the new grid; we still wait to
            // commit to AppStorage until .ended.
            currentFontSize = clamped
        case .ended:
            let final = currentFontSize
            onFontSizePinched?(final)
            gesture.scale = 1.0
        case .cancelled, .failed:
            currentFontSize = pinchStartFontSize
        default:
            break
        }
    }

    // MARK: - Edit menu (Copy / Paste / Select All)

    private func presentEditMenu() {
        guard renderer?.currentSelectionRange() != nil else { return }
        guard window != nil else { return }
        // Anchor at the union of the painted selection rectangles so the
        // menu lands above the highlight instead of the finger.
        let anchor = selectionOverlay.selectionUnionRect()
        let center = anchor?.origin ?? bounds.center
        let configuration = UIEditMenuConfiguration(identifier: "litter.terminal.edit-menu" as NSString, sourcePoint: center)
        if let rect = anchor {
            // Provide a custom target rect via the delegate callback below.
            editMenu.presentEditMenu(with: configuration)
            _ = rect // captured by editMenuInteraction(_:targetRectFor:)
        } else {
            editMenu.presentEditMenu(with: configuration)
        }
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        selectionOverlay.selectionUnionRect() ?? CGRect(origin: bounds.center, size: .zero)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let copy = UIAction(title: "Copy") { [weak self] _ in
            self?.copySelection()
        }
        let paste = UIAction(title: "Paste") { [weak self] _ in
            self?.pasteFromClipboard()
        }
        paste.attributes = UIPasteboard.general.hasStrings ? [] : .disabled
        let selectAll = UIAction(title: "Select All") { [weak self] _ in
            self?.selectAll()
        }
        return UIMenu(children: [copy, paste, selectAll])
    }

    private func copySelection() {
        guard let renderer else { return }
        if let text = renderer.readSelection(), !text.isEmpty {
            UIPasteboard.general.string = text
        }
        renderer.selectionClear()
    }

    private func pasteFromClipboard() {
        guard let renderer, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        renderer.selectionClear()
        renderer.sendPaste(text)
    }

    private func selectAll() {
        _ = renderer?.selectionAll()
        // Re-present the menu over the new range so the user gets a
        // chance to immediately Copy without a second long-press.
        DispatchQueue.main.async { [weak self] in
            self?.presentEditMenu()
        }
    }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            guard !isDismantled else { return }
            isUserInteractionEnabled = true
            gestureRecognizers?.forEach { $0.isEnabled = true }
            if keyboardOverlay.accessoryBar == nil {
                keyboardOverlay.accessoryBar = accessoryBar
            }
            keyboardOverlay.renderer = renderer
            selectionOverlay.setContentScale(contentScale)
            renderer?.attach(to: self)
            renderer?.setOccluded(false)
            // Re-attach can happen after `parkForTemporaryDetach()` left
            // focus = false. Restore it so the Ghostty surface accepts
            // text input again.
            renderer?.setFocused(true)
            _ = focusTerminalInput()
        } else {
            if !isDismantled {
                parkForTemporaryDetach()
            }
        }
    }

    /// UIKit can temporarily remove a representable view from a window
    /// during navigation transitions. Park focus, but keep recognizers and
    /// the accessory bar intact in case the same view is reattached.
    private func parkForTemporaryDetach() {
        keyboardIsVisible = false
        keyboardOverlay.resignFirstResponder()
        _ = resignFirstResponder()
        renderer?.setFocused(false)
        renderer?.setOccluded(true)
    }

    /// Final teardown from `UIViewRepresentable.dismantleUIView`.
    func teardownForDismissal() {
        isDismantled = true
        isUserInteractionEnabled = false
        gestureRecognizers?.forEach { $0.isEnabled = false }
        keyboardOverlay.renderer = nil
        // Clear the accessory bar reference; the overlay's
        // `inputAccessoryView` override reads from `accessoryBar` so
        // setting it to nil drops the docked bar above the keyboard.
        keyboardOverlay.accessoryBar = nil
        keyboardOverlay.resignFirstResponder()
        endEditing(true)
        _ = resignFirstResponder()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isDismantled else { return }
        let scale = contentScale
        renderer?.resize(width: bounds.width, height: bounds.height, scale: scale)
        selectionOverlay.setContentScale(scale)
        selectionOverlay.metrics = renderer?.cellMetrics()
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        updateKeyboardVisibility(from: notification)
        // SwiftUI's GeometryReader receives a new size when SwiftUI's
        // safe-area path adjusts for the keyboard; that re-fires
        // `resizeTerminal(for:)` on the SwiftUI side. We re-trigger
        // layoutSubviews here as a belt-and-suspenders to recompute the
        // grid promptly in case SwiftUI doesn't push a new size (e.g.
        // when the keyboard slides on a screen that already uses
        // ignoresSafeArea on its content area).
        setNeedsLayout()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardIsVisible = false
        setNeedsLayout()
    }

    // MARK: - Helpers

    @discardableResult
    private func focusTerminalInput(forceRefresh: Bool = false) -> Bool {
        guard !isDismantled, window != nil else { return false }
        if keyboardOverlay.accessoryBar == nil {
            keyboardOverlay.accessoryBar = accessoryBar
        }
        keyboardOverlay.renderer = renderer
        renderer?.setFocused(true)

        if keyboardOverlay.isFirstResponder {
            keyboardOverlay.reloadInputViews()
            if forceRefresh && !keyboardIsVisible {
                keyboardOverlay.resignFirstResponder()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil, !self.isDismantled else { return }
                    self.keyboardOverlay.becomeFirstResponder()
                    self.renderer?.setFocused(true)
                }
            }
            return true
        }

        return keyboardOverlay.becomeFirstResponder()
    }

    private func updateKeyboardVisibility(from notification: Notification) {
        guard let window,
              let screenFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let keyboardFrame = window.convert(screenFrame, from: nil)
        keyboardIsVisible = keyboardFrame.intersects(window.bounds) && keyboardFrame.minY < window.bounds.maxY
    }

    private var contentScale: CGFloat {
        window?.screen.scale ?? UIScreen.main.scale
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Long-press takes priority over scroll/drag pans; tap and pinch
        // coexist with everything else so the user can pinch while
        // long-pressing or tap between drags.
        if gestureRecognizer === longPress || other === longPress {
            return true
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        // Scroll pan must wait for long-press to fail; once long-press
        // starts, we want the user's drag to extend the selection rather
        // than scroll the viewport.
        if gestureRecognizer === scrollPan && other === longPress {
            return true
        }
        return false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        if touch.view is UIControl { return false }
        return true
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
