import SwiftUI
import WatchKit

/// 2 · Dictate — opens the native watchOS text input controller (Scribble
/// / Dictate / Emoji). Real transcription from Apple's system dictation;
/// the resulting text is forwarded to the iPhone, which routes it into
/// the active conversation composer.
struct VoiceScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: WatchAppStore

    @State private var status: Status = .idle
    @State private var lastPrompt: String?

    enum Status: Equatable {
        case idle
        case sending
        case sent
        case queued
        case failed(String)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(WatchTheme.ginger)
                    WatchEyebrow(
                        text: store.focusedTask.map { "dictate · \($0.serverName)" } ?? "dictate",
                        size: 9
                    )
                    Spacer(minLength: 0)
                }

                Button {
                    beginDictation()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [WatchTheme.gingerLight, WatchTheme.ginger, WatchTheme.amber],
                                    center: .init(x: 0.35, y: 0.3),
                                    startRadius: 2,
                                    endRadius: 56
                                )
                            )
                            .shadow(color: WatchTheme.ginger.opacity(0.5), radius: 14)
                            .frame(width: 92, height: 92)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 36, weight: .heavy))
                            .foregroundStyle(WatchTheme.onAccent)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start dictation")

                Group {
                    switch status {
                    case .idle:
                        Text("tap to speak")
                            .font(WatchTheme.mono(11, weight: .bold))
                            .foregroundStyle(WatchTheme.gingerLight)
                    case .sending:
                        Text("sending…")
                            .font(WatchTheme.mono(11))
                            .foregroundStyle(WatchTheme.dim)
                    case .sent:
                        (
                            Text("sent ")
                                .foregroundStyle(WatchTheme.successSoft)
                            + Text(lastPrompt ?? "")
                                .foregroundStyle(WatchTheme.dim)
                        )
                        .font(WatchTheme.mono(10))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    case .queued:
                        (
                            Text("queued ")
                                .foregroundStyle(WatchTheme.gingerLight)
                            + Text(lastPrompt ?? "")
                                .foregroundStyle(WatchTheme.dim)
                        )
                        .font(WatchTheme.mono(10))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    case .failed(let reason):
                        Text(reason)
                            .font(WatchTheme.mono(10))
                            .foregroundStyle(WatchTheme.danger)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 4)

                if !store.isReachable {
                    Text("iphone unreachable — will queue")
                        .font(WatchTheme.mono(9))
                        .foregroundStyle(WatchTheme.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .containerBackground(
            RadialGradient(
                colors: [WatchTheme.ginger.opacity(0.18), .black],
                center: .init(x: 0.5, y: 0.7),
                startRadius: 6, endRadius: 200
            ),
            for: .navigation
        )
    }

    // MARK: - Dictation

    private func beginDictation() {
        WatchDictation.request { result in
            switch result {
            case .text(let string):
                send(string)
            case .cancelled:
                status = .idle
            case .unavailable:
                status = .failed("dictation unavailable")
            }
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = .idle
            return
        }
        status = .sending
        lastPrompt = trimmed
        let focused = store.focusedTask
        WatchSessionBridge.shared.sendPrompt(
            trimmed,
            serverId: focused?.serverId,
            threadId: focused?.threadId
        ) { result in
            switch result {
            case .sent:    status = .sent
            case .queued:  status = .queued
            case .failed(let reason): status = .failed(reason)
            }
        }
    }
}

/// Bridge from SwiftUI to watchOS's `presentTextInputController` — the only
/// API that gives us the real Scribble / Dictate / Emoji picker.
enum WatchDictation {
    enum Result {
        case text(String)
        case cancelled
        case unavailable
    }

    static func request(_ completion: @escaping (Result) -> Void) {
        guard let controller = Self.visibleInterfaceController() else {
            completion(.unavailable)
            return
        }
        controller.presentTextInputController(
            withSuggestions: [],
            allowedInputMode: .plain
        ) { results in
            if let string = results?.compactMap({ $0 as? String }).first, !string.isEmpty {
                DispatchQueue.main.async { completion(.text(string)) }
            } else {
                DispatchQueue.main.async { completion(.cancelled) }
            }
        }
    }

    /// SwiftUI doesn't hand out `WKInterfaceController` references, but the
    /// root interface controller is reachable through the singleton.
    private static func visibleInterfaceController() -> WKInterfaceController? {
        WKApplication.shared().rootInterfaceController
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        VoiceScreen()
            .environmentObject(WatchAppStore.previewStore())
    }
}
#endif
