import CoreFoundation
import Foundation

enum VoiceSessionControl {
    static let defaultPrompt = "You are Codex in a live voice conversation inside Litter. Keep responses short, spoken, and conversational. Avoid markdown and code formatting unless explicitly asked."

    /// Build a voice prompt that includes awareness of available servers.
    static func buildPrompt(remoteServers: [(name: String, hostname: String)]) -> String {
        var serverLines = ["- \"local\" (this device)"]
        serverLines.append(contentsOf: remoteServers.map { "- \"\($0.name)\" (\($0.hostname))" })
        let serverList = serverLines.joined(separator: "\n")
        return """
        \(defaultPrompt)

        Available servers:
        \(serverList)
        When using the codex tool, you MUST specify the "server" parameter. \
        IMPORTANT: Use the local discovery tools for server and session lookup. \
        The "local" server has special tools that can see sessions across ALL connected servers in one call. \
        After calling `list_servers` or `list_sessions`, always give the user a short spoken summary of what you found. Do not stop after the tool result alone. \
        Remote servers do NOT have these tools — never ask a remote server to list sessions. \
        Use a remote server name ONLY to run coding tasks, shell commands, or file operations on that machine.
        """
    }

    private static let appGroupSuite = LitterPalette.appGroupSuite
    private static let endRequestKey = "voice_session.end_request_token"
    static let endRequestDarwinNotification = "com.sigkitten.litter.voice_session.end_request"

    static func requestEnd() {
        let token = UUID().uuidString
        UserDefaults(suiteName: appGroupSuite)?.set(token, forKey: endRequestKey)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(endRequestDarwinNotification as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }

    static func pendingEndRequestToken(after lastSeenToken: String?) -> String? {
        guard let token = UserDefaults(suiteName: appGroupSuite)?.string(forKey: endRequestKey),
              !token.isEmpty,
              token != lastSeenToken else {
            return nil
        }
        return token
    }
}
