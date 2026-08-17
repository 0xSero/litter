#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

extension Notification.Name {
    static let litterCommandNewSession = Notification.Name("com.litter.command.newSession")
    static let litterCommandSendComposer = Notification.Name("com.litter.command.sendComposer")
    static let litterCommandNavigateBack = Notification.Name("com.litter.command.navigateBack")
    static let litterCommandNavigateForward = Notification.Name("com.litter.command.navigateForward")
    /// Posted with userInfo `["index": Int]` where `index` is 0-based.
    static let litterCommandSelectSession = Notification.Name("com.litter.command.selectSession")
    static let litterCommandShowSettings = Notification.Name("com.litter.command.showSettings")
}

struct LitterCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                NotificationCenter.default.post(name: .litterCommandNewSession, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("New Window") {
                openNewWindow()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        SidebarCommands()

        CommandMenu("Session") {
            Button("Send") {
                NotificationCenter.default.post(name: .litterCommandSendComposer, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [.command])

            Button("Back") {
                NotificationCenter.default.post(name: .litterCommandNavigateBack, object: nil)
            }
            .keyboardShortcut("[", modifiers: [.command])

            Button("Forward") {
                NotificationCenter.default.post(name: .litterCommandNavigateForward, object: nil)
            }
            .keyboardShortcut("]", modifiers: [.command])

            Divider()

            SessionShortcutsMenu(appModel: appModel)
        }
    }
}

private struct SessionShortcutsMenu: View {
    let appModel: AppModel
    @State private var summaries: [AppSessionSummary] = []

    var body: some View {
        ForEach(0..<9, id: \.self) { index in
            let shortcutKey = KeyEquivalent(Character("\(index + 1)"))
            let summary: AppSessionSummary? = summaries.indices.contains(index) ? summaries[index] : nil
            Button(label(for: summary, index: index)) {
                guard summary != nil else { return }
                NotificationCenter.default.post(
                    name: .litterCommandSelectSession,
                    object: nil,
                    userInfo: ["index": index]
                )
            }
            .keyboardShortcut(shortcutKey, modifiers: [.command])
            .disabled(summary == nil)
        }
        .onAppear { summaries = appModel.snapshot?.sessionSummaries ?? [] }
        .onChange(of: appModel.snapshotRevision) { _, _ in
            summaries = appModel.snapshot?.sessionSummaries ?? []
        }
    }

    private func label(for summary: AppSessionSummary?, index: Int) -> String {
        guard let summary else { return "Session \(index + 1)" }
        return "Session \(index + 1): \(summary.displayTitle)"
    }
}

@MainActor
private func openNewWindow() {
    UIApplication.shared.requestSceneSessionActivation(
        nil,
        userActivity: nil,
        options: nil,
        errorHandler: { error in
            LLog.error("multiwindow", "open failed", error: error)
        }
    )
}

/// Catalyst window setup: keeps the underlying NSWindow opaque (so the
/// desktop can't bleed through sidebar Liquid Glass), installs a
/// compact unified titlebar with an NSToolbar carrying the settings
/// button next to the traffic lights, and declares the window's
/// resize bounds.
struct MacWindowTitleBarStyler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = SceneConfigView()
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class SceneConfigView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Force the Catalyst UIWindow opaque so the desktop can't
            // bleed through NavigationSplitView's sidebar Liquid Glass
            // material. Paint black behind SwiftUI so any remaining
            // translucency still resolves to a dark surface, not the
            // Mac desktop.
            if let window {
                window.isOpaque = true
                window.backgroundColor = .black
            }

            DispatchQueue.main.async { [weak self] in
                guard let windowScene = self?.window?.windowScene else { return }
                if let titlebar = windowScene.titlebar {
                    titlebar.titleVisibility = .hidden
                    titlebar.toolbar = nil
                }
                let restrictions = windowScene.sizeRestrictions
                restrictions?.minimumSize = CGSize(width: 760, height: 560)
                restrictions?.maximumSize = CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        }
    }
}
#endif
