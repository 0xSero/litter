import SwiftUI

/// Capsule voice button matching the `+` and search buttons in
/// `HomeBottomBar`. Size and glass treatment are identical; only the icon
/// and its tint change to reflect realtime voice state.
struct HomeVoiceOrbButton: View {
    let session: VoiceSessionState?
    let isAvailable: Bool
    let isStarting: Bool
    let action: () -> Void

    private let buttonSize: CGFloat = 44

    private var phase: VoiceSessionPhase? {
        if isStarting { return .connecting }
        return session?.phase
    }

    private var isActive: Bool {
        phase != nil && phase != .error
    }

    private var hasRecoverableError: Bool {
        phase == .error
    }

    private var isDisabled: Bool {
        !isAvailable || isStarting || (session != nil && !hasRecoverableError)
    }

    private var accessibilityLabel: String {
        if !isAvailable { return "Realtime voice unavailable" }
        if isStarting { return "Connecting realtime voice" }
        if hasRecoverableError { return "Retry realtime voice" }
        return "Start realtime voice"
    }

    /// Tint for the mic glyph. When the session is live we use a warmer
    /// accent; error falls back to the danger color. Idle matches the
    /// muted glyph color used by the search button.
    private var iconColor: Color {
        guard let phase else { return LitterTheme.textSecondary }
        switch phase {
        case .connecting, .listening:
            return LitterTheme.accent
        case .speaking, .thinking, .handoff:
            return LitterTheme.warning
        case .error:
            return LitterTheme.danger
        }
    }


    var body: some View {
        Button(action: action) {
            Group {
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(iconColor)
                } else {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(RaisedCapsuleModifier())
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Starts a local realtime voice conversation.")
        .coachmarkAnchor(.voice)
    }
}
