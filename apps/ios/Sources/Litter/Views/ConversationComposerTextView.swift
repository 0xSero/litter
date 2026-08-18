import SwiftUI
import UIKit

/// Holds the composer's UIKit selection range *outside* SwiftUI state.
///
/// The range is pure edit plumbing: nothing draws it. Its only readers are the
/// transcript-insert and composer-prefill handlers, which query it on demand.
/// Routing it through `@State` meant every keystroke published an extra
/// invalidation of the whole composer subtree (the coordinator writes it from
/// both `textViewDidChange` and `textViewDidChangeSelection`) for a value no
/// body ever reads. A reference box keeps the *synchronous* write behaviour
/// that `Coordinator.updateSelectedRange` depends on to avoid reordering edits,
/// at zero body passes.
///
/// Owning views keep it alive with `@State private var selection = ComposerSelectionBox()`
/// and hand `selection.binding` to the composer instead of `$someNSRangeState`.
/// Readers/writers use `selection.range` directly.
final class ComposerSelectionBox {
    var range: NSRange

    init(_ range: NSRange = NSRange(location: 0, length: 0)) {
        self.range = range
    }

    /// Bridges the box into the existing `Binding<NSRange>` plumbing. Writes
    /// land on the box, never on SwiftUI state, so they invalidate nothing.
    var binding: Binding<NSRange> {
        Binding(
            get: { self.range },
            set: { self.range = $0 }
        )
    }
}

struct ConversationComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var selectedRange: NSRange
    let onPasteImage: (UIImage) -> Void
    /// Invoked when the user presses hardware Return with no modifiers. Shift+Return
    /// still inserts a newline via the standard text-view behavior.
    var onHardwareSubmit: (() -> Void)? = nil
    /// Insets are presentation-only. Keeping them on the existing UIKit text
    /// view lets the composer chrome change without replacing its text state,
    /// selection, marked-text, or autocorrection path.
    var horizontalInset: CGFloat = 16
    var verticalInset: CGFloat = 11
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
        horizontalInset: CGFloat = 16,
        verticalInset: CGFloat = 11,
        unboundedHeight: Bool = false
    ) {
        _text = text
        _isFocused = isFocused
        _selectedRange = selectedRange
        self.onPasteImage = onPasteImage
        self.onHardwareSubmit = onHardwareSubmit
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset
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
        textView.textContainerInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
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
        textView.accessibilityIdentifier = "conversation.composerTextView"
        textView.text = text
        context.coordinator.textReconciler = ComposerTextReconciler(initialText: text)
        context.coordinator.applyStyling(to: textView)
        context.coordinator.updateScrollState(for: textView)
        return textView
    }

    func updateUIView(_ uiView: PasteAwareComposerUITextView, context: Context) {
        context.coordinator.parent = self
        uiView.onPasteImage = onPasteImage
        uiView.onHardwareSubmit = onHardwareSubmit
        let nextInsets = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
        if uiView.textContainerInset != nextInsets {
            uiView.textContainerInset = nextInsets
        }
        context.coordinator.applyStyling(to: uiView)

        if uiView.markedTextRange == nil,
           context.coordinator.textReconciler.shouldApply(
               presentedText: text,
               currentUIKitText: uiView.text,
               isEditing: uiView.isFirstResponder
           ) {
            context.coordinator.isSynchronizingText = true
            uiView.text = text
            context.coordinator.applySelectedRange(to: uiView)
            context.coordinator.isSynchronizingText = false
        } else if !uiView.isFirstResponder {
            context.coordinator.applySelectedRange(to: uiView)
        }

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
        var textReconciler: ComposerTextReconciler
        private var requestedFocusState: Bool?
        private var focusSyncWorkItem: DispatchWorkItem?
        /// `LitterFont.uiFont` reads `UserDefaults` and probes `UIFont(name:)`
        /// up to twice on every call, and `applyStyling` runs from every
        /// `updateUIView` — i.e. several times per keystroke. Cache the
        /// resolved font per coordinator (one per text view) keyed on the
        /// Dynamic Type point size plus the app's font-preference revision,
        /// which `SettingsView` bumps whenever the family changes.
        private var cachedFont: UIFont?
        private var cachedFontPointSize: CGFloat = 0
        private var cachedFontRevision: Int = -1

        init(_ parent: ConversationComposerTextView) {
            self.parent = parent
            textReconciler = ComposerTextReconciler(initialText: parent.text)
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
            textReconciler.recordUIKitEdit(updatedText)
            if parent.text != updatedText {
                parent.text = updatedText
            }
            updateSelectedRange(from: textView)
            // While focused the view is already scroll-enabled. Avoid forcing
            // TextKit to measure the entire draft again for every keystroke.
            if !textView.isFirstResponder {
                updateScrollState(for: textView)
            }
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
            let font = composerFont()
            if textView.font != font {
                textView.font = font
            }
            let color = UIColor(LitterTheme.textPrimary)
            if textView.textColor != color {
                textView.textColor = color
            }
        }

        func updateScrollState(for textView: UITextView) {
            if parent.isFocused || textView.isFirstResponder {
                if !textView.isScrollEnabled { textView.isScrollEnabled = true }
                if !textView.alwaysBounceVertical { textView.alwaysBounceVertical = true }
                return
            }
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
            let revision = FontPreferenceObserver.shared.revision
            if let cachedFont,
               cachedFontPointSize == pointSize,
               cachedFontRevision == revision {
                return cachedFont
            }
            let font = LitterFont.uiFont(size: pointSize)
            cachedFont = font
            cachedFontPointSize = pointSize
            cachedFontRevision = revision
            return font
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
            // UITextView delegate callbacks are already on the main thread.
            // Writing selection asynchronously lets older cursor positions
            // arrive after newer keystrokes and can visibly reorder edits.
            parent.selectedRange = range
        }
    }
}

/// Keeps UIKit authoritative while the user is actively editing. SwiftUI may
/// re-render the representable with the previously presented binding value
/// before the latest delegate write has propagated. Re-applying that stale
/// value resets autocorrection state and the cursor, causing lag and scrambled
/// characters during rapid typing.
struct ComposerTextReconciler {
    private(set) var lastPresentedText: String
    private(set) var lastUIKitEdit: String?

    init(initialText: String) {
        lastPresentedText = initialText
    }

    mutating func recordUIKitEdit(_ text: String) {
        lastUIKitEdit = text
    }

    mutating func shouldApply(
        presentedText: String,
        currentUIKitText: String,
        isEditing: Bool
    ) -> Bool {
        defer { lastPresentedText = presentedText }
        guard presentedText != currentUIKitText else {
            if lastUIKitEdit == presentedText { lastUIKitEdit = nil }
            return false
        }

        if isEditing,
           presentedText == lastPresentedText,
           currentUIKitText == lastUIKitEdit {
            return false
        }

        lastUIKitEdit = nil
        return true
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
