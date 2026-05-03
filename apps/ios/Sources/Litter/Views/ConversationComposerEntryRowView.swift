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
    let onPasteImage: (UIImage) -> Void
    let onSendText: () -> Void
    let onStopRecording: () -> Void
    let onStartRecording: () -> Void
    let onInterrupt: () -> Void

    private enum Metrics {
        static let controlSize: CGFloat = 44
        static let inputCornerRadius: CGFloat = controlSize / 2
        static let trailingControlSize: CGFloat = 44
        static let horizontalPadding: CGFloat = 10
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
        onPasteImage: @escaping (UIImage) -> Void,
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
        self.onPasteImage = onPasteImage
        self.onSendText = onSendText
        self.onStopRecording = onStopRecording
        self.onStartRecording = onStartRecording
        self.onInterrupt = onInterrupt
    }

    @State private var showExpanded: Bool = false

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSend: Bool {
        hasText || hasAttachment
    }

    /// Show the expand affordance once the composer is multi-line or starts to
    /// wrap, matching ChatGPT's behaviour. Short prompts stay clutter-free.
    private var shouldShowExpand: Bool {
        !voiceManager.isRecording
            && !voiceManager.isTranscribing
            && (inputText.contains("\n") || inputText.count > 60)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !voiceManager.isRecording && !voiceManager.isTranscribing && !isTurnActive {
                Button {
                    showAttachMenu = true
                } label: {
                    Image(systemName: "plus")
                        .font(LitterFont.styled(size: 20, weight: .semibold))
                        .foregroundColor(LitterTheme.textPrimary)
                        .frame(width: Metrics.controlSize, height: Metrics.controlSize)
                        .modifier(GlassCircleModifier())
                }
                .padding(4)
                .contentShape(Rectangle())
                .padding(-4)
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Attach")
                .zIndex(1)
            }

            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ConversationComposerTextView(
                        text: $inputText,
                        isFocused: $isComposerFocused,
                        selectedRange: $composerSelectionRange,
                        onPasteImage: onPasteImage,
                        onHardwareSubmit: {
                            if canSend { onSendText() }
                        }
                    )

                    if inputText.isEmpty {
                        Text("Message litter...")
                            .font(LitterFont.styled(size: 17))
                            .foregroundColor(LitterTheme.textMuted)
                            .padding(.leading, 16)
                            .padding(.top, 11)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if voiceManager.isRecording {
                    AudioWaveformView(level: voiceManager.audioLevel)
                        .frame(width: 48, height: 20)

                    Button(action: onStopRecording) {
                        Image(systemName: "stop.circle.fill")
                            .font(LitterFont.styled(size: 28))
                            .foregroundColor(LitterTheme.accentStrong)
                            .frame(width: Metrics.trailingControlSize, height: Metrics.trailingControlSize)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel("Stop recording")
                } else if voiceManager.isTranscribing {
                    ProgressView()
                        .tint(LitterTheme.accent)
                        .frame(width: Metrics.trailingControlSize, height: Metrics.trailingControlSize)
                } else if allowsVoiceInput {
                    Button(action: onStartRecording) {
                        Image(systemName: "mic.fill")
                            .font(LitterFont.styled(size: 18))
                            .foregroundColor(LitterTheme.textSecondary)
                            .frame(width: Metrics.trailingControlSize, height: Metrics.trailingControlSize)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel("Dictate")
                }
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.controlSize)
            .modifier(GlassRoundedRectModifier(cornerRadius: Metrics.inputCornerRadius))
            .overlay(alignment: .topTrailing) {
                if shouldShowExpand {
                    Button {
                        showExpanded = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(LitterFont.styled(size: 12, weight: .semibold))
                            .foregroundColor(LitterTheme.textSecondary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .hoverEffect(.highlight)
                    .padding(.top, 2)
                    .padding(.trailing, 6)
                    .accessibilityLabel("Expand composer")
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: shouldShowExpand)

            if canSend {
                Button(action: onSendText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(LitterFont.styled(size: 30))
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: Metrics.trailingControlSize, height: Metrics.trailingControlSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .disabled(voiceManager.isRecording || voiceManager.isTranscribing)
                .opacity(voiceManager.isRecording || voiceManager.isTranscribing ? 0.45 : 1)
                .accessibilityLabel("Send")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if isTurnActive && !canSend {
                Button(action: onInterrupt) {
                    Text("Cancel")
                        .font(LitterFont.styled(size: 15, weight: .medium))
                        .foregroundColor(LitterTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: Metrics.controlSize)
                        .modifier(GlassCapsuleModifier())
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: isTurnActive)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: canSend)
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
}
