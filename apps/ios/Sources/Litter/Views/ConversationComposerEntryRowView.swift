import SwiftUI
import UIKit

struct ConversationComposerEntryRowView: View {
    @Binding var showAttachMenu: Bool
    @Binding var inputText: String
    @Binding var isComposerFocused: Bool
    @Binding var composerSelectionRange: NSRange
    let voiceManager: VoiceTranscriptionManager
    let isTurnActive: Bool
    let hasAttachment: Bool
    let allowsVoiceInput: Bool
    let modelLabel: String?
    let reasoningLabel: String?
    let collaborationMode: AppModeKind
    let showModeChip: Bool
    let onPasteImage: (UIImage) -> Void
    let onOpenModelPicker: () -> Void
    let onOpenModePicker: () -> Void
    let onSendText: () -> Void
    let onStopRecording: () -> Void
    let onStartRecording: () -> Void
    let onInterrupt: () -> Void

    private enum Metrics {
        static let controlSize: CGFloat = LitterSpace.hitTarget
        static let inputCornerRadius: CGFloat = LitterRadius.composer
        static let trailingControlSize: CGFloat = LitterSpace.hitTarget
        static let horizontalPadding: CGFloat = LitterSpace.m
        static let verticalPadding: CGFloat = 6
    }

    init(
        showAttachMenu: Binding<Bool>,
        inputText: Binding<String>,
        isComposerFocused: Binding<Bool>,
        composerSelectionRange: Binding<NSRange> = .constant(NSRange(location: 0, length: 0)),
        voiceManager: VoiceTranscriptionManager,
        isTurnActive: Bool,
        hasAttachment: Bool,
        allowsVoiceInput: Bool = true,
        modelLabel: String? = nil,
        reasoningLabel: String? = nil,
        collaborationMode: AppModeKind = .`default`,
        showModeChip: Bool = false,
        onPasteImage: @escaping (UIImage) -> Void,
        onOpenModelPicker: @escaping () -> Void = {},
        onOpenModePicker: @escaping () -> Void = {},
        onSendText: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onInterrupt: @escaping () -> Void
    ) {
        _showAttachMenu = showAttachMenu
        _inputText = inputText
        _isComposerFocused = isComposerFocused
        _composerSelectionRange = composerSelectionRange
        self.voiceManager = voiceManager
        self.isTurnActive = isTurnActive
        self.hasAttachment = hasAttachment
        self.allowsVoiceInput = allowsVoiceInput
        self.modelLabel = modelLabel
        self.reasoningLabel = reasoningLabel
        self.collaborationMode = collaborationMode
        self.showModeChip = showModeChip
        self.onPasteImage = onPasteImage
        self.onOpenModelPicker = onOpenModelPicker
        self.onOpenModePicker = onOpenModePicker
        self.onSendText = onSendText
        self.onStopRecording = onStopRecording
        self.onStartRecording = onStartRecording
        self.onInterrupt = onInterrupt
    }

    @State private var showExpanded: Bool = false

    /// Equivalent to `!inputText.trimmingCharacters(in: .whitespaces).isEmpty`
    /// without allocating a trimmed copy of the whole draft on every body
    /// pass. `.whitespaces` does not include newlines, so a newline still
    /// counts as content — hence the explicit `isNewline` arm.
    private var hasText: Bool {
        inputText.contains(where: { !$0.isWhitespace || $0.isNewline })
    }

    private var canSend: Bool {
        hasText || hasAttachment
    }

    /// Show the expand affordance once the composer is multi-line or starts to
    /// wrap, matching ChatGPT's behaviour. Short prompts stay clutter-free.
    private var shouldShowExpand: Bool {
        !voiceManager.isRecording
            && !voiceManager.isTranscribing
            && isMultilineOrLong
    }

    /// Same predicate as `inputText.contains("\n") || inputText.count > 60`,
    /// but one early-exiting pass bounded at 61 characters instead of two full
    /// walks of the draft on every body pass.
    private var isMultilineOrLong: Bool {
        var count = 0
        for character in inputText {
            if character == "\n" { return true }
            count += 1
            if count > 60 { return true }
        }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            textEditor
            actionRow
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.inputCornerRadius, style: .continuous)
                .fill(LitterTheme.composerFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.inputCornerRadius, style: .continuous)
                .strokeBorder(LitterTheme.composerOutline, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: isTurnActive)
        .animation(.easeOut(duration: 0.18), value: canSend)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.top, Metrics.verticalPadding)
        .padding(.bottom, Metrics.verticalPadding)
        .fullScreenCover(isPresented: $showExpanded) {
            ConversationComposerExpandedView(
                inputText: $inputText,
                isPresented: $showExpanded,
                onPasteImage: onPasteImage,
                onSend: onSendText,
                hasAttachment: hasAttachment
            )
        }
    }

    private var textEditor: some View {
        ZStack(alignment: .topLeading) {
            ConversationComposerTextView(
                text: $inputText,
                isFocused: $isComposerFocused,
                selectedRange: $composerSelectionRange,
                onPasteImage: onPasteImage,
                onHardwareSubmit: {
                    if canSend { onSendText() }
                },
                horizontalInset: LitterSpace.composerInset,
                verticalInset: LitterSpace.composerInset
            )

            if inputText.isEmpty {
                Text("Type / for commands")
                    .font(LitterFont.styled(size: 17))
                    .foregroundColor(LitterTheme.textMuted)
                    .padding(.leading, LitterSpace.composerInset)
                    .padding(.top, LitterSpace.composerInset)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if shouldShowExpand {
                Button {
                    showExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(LitterFont.styled(size: 12, weight: .semibold))
                        .foregroundColor(LitterTheme.textSecondary)
                        .padding(LitterSpace.m)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Expand composer")
                .transition(.opacity)
            }
        }
    }

    private var isVoiceBusy: Bool {
        voiceManager.isRecording || voiceManager.isTranscribing
    }

    private var actionRow: some View {
        HStack(spacing: LitterSpace.s) {
            if !isVoiceBusy {
                composerCircleButton(systemName: "plus", label: "Attach") {
                    showAttachMenu = true
                }
            }

            if let modelLabel {
                Button(action: onOpenModelPicker) {
                    HStack(spacing: 6) {
                        Text(modelLabel)
                            .foregroundColor(LitterTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let reasoningLabel, reasoningLabel != "default" {
                            Text(reasoningLabel)
                                .foregroundColor(LitterTheme.meta)
                                .lineLimit(1)
                        }
                    }
                    .font(LitterFont.styled(size: 16))
                    .padding(.horizontal, LitterSpace.l)
                    .frame(height: Metrics.controlSize)
                    .background(Capsule().fill(LitterTheme.composerControl))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityIdentifier("conversation.modelPickerButton")
                .accessibilityLabel("Choose model")
                .frame(maxWidth: 190, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }

            if showModeChip {
                ConversationComposerModeChip(mode: collaborationMode, onTap: onOpenModePicker)
            }

            Spacer(minLength: 0)

            if voiceManager.isRecording {
                AudioWaveformView(level: voiceManager.audioLevel)
                    .frame(width: 42, height: 20)
            }
            voiceControl
                .fixedSize()
            trailingControl
                .fixedSize()
                .layoutPriority(3)
        }
        .padding(.horizontal, LitterSpace.m)
        .padding(.top, LitterSpace.xs)
        .padding(.bottom, LitterSpace.m)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var voiceControl: some View {
        if voiceManager.isRecording {
            composerCircleButton(systemName: "stop.fill", label: "Stop recording", tint: LitterTheme.surface, fill: LitterTheme.textPrimary) {
                onStopRecording()
            }
        } else if voiceManager.isTranscribing {
            ProgressView()
                .tint(LitterTheme.textSecondary)
                .frame(width: Metrics.trailingControlSize, height: Metrics.trailingControlSize)
        } else if allowsVoiceInput {
            composerCircleButton(systemName: "mic", label: "Dictate", tint: LitterTheme.textSecondary) {
                onStartRecording()
            }
        }
    }

    /// Send, or stop while the agent runs and the draft is empty. A non-empty
    /// draft during a running turn still sends (queues a follow-up).
    @ViewBuilder
    private var trailingControl: some View {
        if isTurnActive && !canSend && !isVoiceBusy {
            composerCircleButton(systemName: "stop.fill", label: "Cancel response", tint: LitterTheme.surface, fill: LitterTheme.textPrimary) {
                onInterrupt()
            }
        } else {
            let enabled = canSend && !isVoiceBusy
            composerCircleButton(
                systemName: "arrow.up",
                label: "Send",
                tint: enabled ? Color.white : LitterTheme.textMuted,
                fill: enabled ? LitterTheme.sendTint : LitterTheme.sendTint.opacity(0.28)
            ) {
                if enabled { onSendText() }
            }
            .disabled(!enabled)
        }
    }

    private func composerCircleButton(
        systemName: String,
        label: String,
        tint: Color = LitterTheme.textPrimary,
        fill: Color = LitterTheme.composerControl,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(LitterFont.styled(size: systemName == "plus" ? 22 : 18, weight: systemName == "plus" ? .regular : .semibold))
                .foregroundColor(tint)
                .frame(width: Metrics.controlSize, height: Metrics.controlSize)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .accessibilityIdentifier("conversation.\(label.lowercased().replacingOccurrences(of: " ", with: "-"))Button")
    }
}
