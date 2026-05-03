import AppIntents

struct LitterWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendPromptIntent(),
            phrases: [
                "Send a task to \(.applicationName)"
            ],
            shortTitle: "Send Task",
            systemImageName: "mic.circle.fill"
        )
    }
}
