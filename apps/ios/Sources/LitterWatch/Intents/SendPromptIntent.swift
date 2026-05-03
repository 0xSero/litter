import AppIntents

struct SendPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Task to Codex"
    static let description = IntentDescription("Dispatch a prompt to your Codex thread.")

    @Parameter(title: "Prompt") var prompt: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            WatchSessionBridge.shared.sendPrompt(prompt, serverId: nil, threadId: nil)
        }
        return .result(dialog: "Sent.")
    }
}
