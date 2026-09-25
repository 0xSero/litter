import SwiftUI
import UIKit
import os

private let conversationWarmupSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "ConversationWarmup"
)

struct ConversationWarmupView: View {
    let warmupID: UUID
    let onComplete: () -> Void

    @State private var warmupInputText = ""
    @State private var shouldPrimeKeyboard = false
    @State private var didCompleteWarmup = false
    @State private var warmupComposerFocused = false
    @State private var warmupShowAttachMenu = false
    @State private var voiceManager = VoiceTranscriptionManager()

    var body: some View {
        ZStack {
            ConversationComposerEntryRowView(
                showAttachMenu: $warmupShowAttachMenu,
                inputText: $warmupInputText,
                isComposerFocused: $warmupComposerFocused,
                voiceManager: voiceManager,
                isTurnActive: false,
                hasAttachment: false,
                onPasteImage: { _ in },
                onSendText: {},
                onStopRecording: {},
                onStartRecording: {},
                onInterrupt: {}
            )
            .frame(width: 220, height: 56)
            .clipped()

            ConversationKeyboardWarmupTextView(
                shouldPrimeKeyboard: $shouldPrimeKeyboard,
                onDidPrimeKeyboard: completeWarmup
            )
            .frame(width: 100, height: 44)
        }
        .offset(x: -9999)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: warmupID) {
            await runWarmup()
        }
    }

    @MainActor
    private func runWarmup() async {
        let signpostID = OSSignpostID(log: conversationWarmupSignpostLog)
        os_signpost(.begin, log: conversationWarmupSignpostLog, name: "PrewarmConversation", signpostID: signpostID)
        defer {
            os_signpost(.end, log: conversationWarmupSignpostLog, name: "PrewarmConversation", signpostID: signpostID)
        }

        do {
            try await Task.sleep(nanoseconds: 60_000_000)
            guard !didCompleteWarmup else { return }
            shouldPrimeKeyboard = true
            try await Task.sleep(nanoseconds: 900_000_000)
        } catch {
            // A disappearing warmup must release its waiters without ever
            // priming a keyboard after cancellation.
        }
        completeWarmup()
    }

    @MainActor
    private func completeWarmup() {
        guard !didCompleteWarmup else { return }
        didCompleteWarmup = true
        shouldPrimeKeyboard = false
        warmupComposerFocused = false
        onComplete()
    }
}

struct ConversationKeyboardWarmupTextView: UIViewRepresentable {
    @Binding var shouldPrimeKeyboard: Bool
    let onDidPrimeKeyboard: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDidPrimeKeyboard: onDidPrimeKeyboard)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: CGRect(x: -9999, y: -9999, width: 100, height: 44))
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        context.coordinator.field = field
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        guard shouldPrimeKeyboard else {
            if uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
            return
        }

        DispatchQueue.main.async {
            guard shouldPrimeKeyboard else { return }
            context.coordinator.primeIfNeeded()
        }
    }

    static func dismantleUIView(_ uiView: UITextField, coordinator: Coordinator) {
        coordinator.cancel()
        uiView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        weak var field: UITextField?
        private(set) var isComplete = false
        private var isPriming = false
        let onDidPrimeKeyboard: () -> Void

        init(onDidPrimeKeyboard: @escaping () -> Void) {
            self.onDidPrimeKeyboard = onDidPrimeKeyboard
        }

        func primeIfNeeded() {
            guard !isComplete, !isPriming else { return }
            guard let field, let window = field.window, window.isKeyWindow,
                  !hasFirstResponder(in: window) else {
                // Real input has already warmed the keyboard. Never replace
                // its responder or activate a background/non-key window.
                finish()
                return
            }
            isPriming = true
            if !field.becomeFirstResponder() { finish() }
        }

        func cancel() { finish() }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { [weak self] in self?.finish() }
        }

        private func finish() {
            guard !isComplete else { return }
            isComplete = true
            if field?.isFirstResponder == true { field?.resignFirstResponder() }
            // Teardown can run during a SwiftUI update; publish completion
            // on the next turn rather than mutating view state in that update.
            DispatchQueue.main.async(execute: onDidPrimeKeyboard)
        }

        private func hasFirstResponder(in view: UIView) -> Bool {
            view.isFirstResponder || view.subviews.contains { hasFirstResponder(in: $0) }
        }
    }
}
