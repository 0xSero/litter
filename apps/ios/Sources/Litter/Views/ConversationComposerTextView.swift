import SwiftUI
import UIKit

struct ConversationComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var selectedRange: NSRange
    let onPasteImage: (UIImage) -> Void
    /// Invoked when the user presses hardware Return with no modifiers. Shift+Return
    /// still inserts a newline via the standard text-view behavior.
    var onHardwareSubmit: (() -> Void)? = nil
    /// When true, the view returns no preferred size from `sizeThatFits`, letting
    /// SwiftUI fill the parent frame. Scrolling kicks in against the actual
    /// bounds instead of the 5-line clamp.
    var unboundedHeight: Bool = false

    init(
        text: Binding<String>,
        isFocused: Binding<Bool>,
        selectedRange: Binding<NSRange> = .constant(NSRange(location: 0, length: 0)),
        onPasteImage: @escaping (UIImage) -> Void,
        onHardwareSubmit: (() -> Void)? = nil,
        unboundedHeight: Bool = false
    ) {
        _text = text
        _isFocused = isFocused
        _selectedRange = selectedRange
        self.onPasteImage = onPasteImage
        self.onHardwareSubmit = onHardwareSubmit
        self.unboundedHeight = unboundedHeight
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PasteAwareComposerUITextView {
        let textView = PasteAwareComposerUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.tintColor = UIColor(LitterTheme.accent)
        textView.textContainerInset = UIEdgeInsets(top: 11, left: 16, bottom: 11, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences
        textView.spellCheckingType = .default
        textView.smartQuotesType = .default
        textView.smartDashesType = .default
        textView.smartInsertDeleteType = .default
        textView.keyboardDismissMode = .interactive
        textView.showsVerticalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.onPasteImage = onPasteImage
        textView.onHardwareSubmit = onHardwareSubmit
        textView.text = text
        context.coordinator.applyStyling(to: textView)
        context.coordinator.updateScrollState(for: textView)
        return textView
    }

    func updateUIView(_ uiView: PasteAwareComposerUITextView, context: Context) {
        context.coordinator.parent = self
        uiView.onPasteImage = onPasteImage
        uiView.onHardwareSubmit = onHardwareSubmit
        context.coordinator.applyStyling(to: uiView)

        if uiView.text != text, uiView.markedTextRange == nil {
            context.coordinator.isSynchronizingText = true
            uiView.text = text
            context.coordinator.applySelectedRange(to: uiView)
            context.coordinator.isSynchronizingText = false
        }

        context.coordinator.applySelectedRange(to: uiView)
        context.coordinator.updateScrollState(for: uiView)
        context.coordinator.syncFocus(for: uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteAwareComposerUITextView, context: Context) -> CGSize? {
        if unboundedHeight { return nil }
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }

        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        let clampedHeight = min(
            max(fittingSize.height, context.coordinator.minimumHeight(for: uiView)),
            context.coordinator.maximumHeight(for: uiView)
        )
        return CGSize(width: width, height: clampedHeight)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ConversationComposerTextView
        var isSynchronizingText = false
        private var requestedFocusState: Bool?
        private var focusSyncWorkItem: DispatchWorkItem?

        init(_ parent: ConversationComposerTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            updateFocusBinding(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            updateFocusBinding(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isSynchronizingText else { return }
            let updatedText = textView.text ?? ""
            if parent.text != updatedText {
                parent.text = updatedText
            }
            updateSelectedRange(from: textView)
            updateScrollState(for: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isSynchronizingText else { return }
            updateSelectedRange(from: textView)
        }

        func syncFocus(for textView: UITextView) {
            let requestedFocus = parent.isFocused
            let needsUIKitSync: Bool = {
                if requestedFocus {
                    return textView.window != nil && !textView.isFirstResponder
                }
                return textView.isFirstResponder
            }()
            guard requestedFocusState != requestedFocus || needsUIKitSync else { return }
            requestedFocusState = requestedFocus

            focusSyncWorkItem?.cancel()
            let work = DispatchWorkItem { [weak textView, weak self] in
                guard let self, let textView else { return }
                self.focusSyncWorkItem = nil
                let latestRequestedFocus = self.requestedFocusState ?? false
                if latestRequestedFocus {
                    guard textView.window != nil, !textView.isFirstResponder else { return }
                    textView.becomeFirstResponder()
                } else if textView.isFirstResponder {
                    textView.resignFirstResponder()
                }
            }
            focusSyncWorkItem = work
            DispatchQueue.main.async(execute: work)
        }

        func applyStyling(to textView: UITextView) {
            textView.font = composerFont()
            textView.textColor = UIColor(LitterTheme.textPrimary)
        }

        func updateScrollState(for textView: UITextView) {
            let availableWidth = max(textView.bounds.width, 1)
            let fittingHeight = textView.sizeThatFits(
                CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
            ).height
            let threshold = parent.unboundedHeight
                ? textView.bounds.height
                : maximumHeight(for: textView)
            let shouldScroll = fittingHeight > threshold + 0.5
            let shouldScrollForDismiss = parent.isFocused || shouldScroll
            if textView.isScrollEnabled != shouldScrollForDismiss {
                textView.isScrollEnabled = shouldScrollForDismiss
            }
            if textView.alwaysBounceVertical != shouldScrollForDismiss {
                textView.alwaysBounceVertical = shouldScrollForDismiss
            }
        }

        func applySelectedRange(to textView: UITextView) {
            let textLength = (textView.text as NSString?)?.length ?? 0
            let clampedLocation = min(max(parent.selectedRange.location, 0), textLength)
            let clampedLength = min(max(parent.selectedRange.length, 0), textLength - clampedLocation)
            let clamped = NSRange(location: clampedLocation, length: clampedLength)
            guard textView.selectedRange.location != clamped.location
                    || textView.selectedRange.length != clamped.length else {
                return
            }
            textView.selectedRange = clamped
        }

        func minimumHeight(for textView: UITextView) -> CGFloat {
            let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            return ceil(lineHeight + textView.textContainerInset.top + textView.textContainerInset.bottom)
        }

        func maximumHeight(for textView: UITextView) -> CGFloat {
            let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            return ceil((lineHeight * 5) + textView.textContainerInset.top + textView.textContainerInset.bottom)
        }

        private func composerFont() -> UIFont {
            let pointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
            if LitterFont.storedFamily.isMono {
                return LitterFont.uiMonoFont(size: pointSize)
            }
            return UIFont.systemFont(ofSize: pointSize)
        }

        private func updateFocusBinding(_ isFocused: Bool) {
            guard parent.isFocused != isFocused else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.isFocused != isFocused else { return }
                self.parent.isFocused = isFocused
            }
        }

        private func updateSelectedRange(from textView: UITextView) {
            let range = textView.selectedRange
            guard parent.selectedRange.location != range.location
                    || parent.selectedRange.length != range.length else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.selectedRange = range
            }
        }
    }
}

final class PasteAwareComposerUITextView: UITextView {
    var onPasteImage: ((UIImage) -> Void)?
    var onHardwareSubmit: (() -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let image = UIPasteboard.general.image {
            onPasteImage?(image)
            return
        }
        super.paste(sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        guard onHardwareSubmit != nil else { return commands }
        let submit = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleHardwareSubmit(_:)))
        submit.wantsPriorityOverSystemBehavior = true
        commands.append(submit)
        return commands
    }

    @objc private func handleHardwareSubmit(_ sender: UIKeyCommand) {
        onHardwareSubmit?()
    }
}

func composerInsertionText(_ insertion: String, in text: NSString, replacing range: NSRange) -> String {
    var replacement = insertion
    let beforeIndex = range.location - 1
    let afterIndex = range.location + range.length

    if beforeIndex >= 0,
       !isComposerWhitespace(text.character(at: beforeIndex)) {
        replacement = " " + replacement
    }

    if afterIndex < text.length,
       !isComposerWhitespace(text.character(at: afterIndex)) {
        replacement += " "
    }

    return replacement
}

private func isComposerWhitespace(_ value: unichar) -> Bool {
    guard let scalar = UnicodeScalar(UInt32(value)) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
}
