import Foundation
import SwiftUI

extension AppServerSnapshot {
    var isConnected: Bool {
        transportState == .connected
    }

    var canUseTransportActions: Bool {
        capabilities.canUseTransportActions
    }

    var canBrowseDirectories: Bool {
        capabilities.canBrowseDirectories
    }

    var connectionModeLabel: String {
        guard !isLocal else { return "local" }
        return "remote"
    }

    var currentConnectionStep: AppConnectionStepSnapshot? {
        guard let progress = connectionProgress else { return nil }
        return progress.steps.first(where: {
            $0.state == .awaitingUserInput || $0.state == .inProgress
        }) ?? progress.steps.last(where: {
            $0.state == .failed || $0.state == .completed
        })
    }

    var connectionProgressLabel: String? {
        guard let step = currentConnectionStep else { return nil }
        switch step.kind {
        case .connectingToSsh:
            return "connecting"
        case .findingCodex:
            return "finding codex"
        case .installingCodex:
            return "installing"
        case .startingAppServer:
            return "starting"
        case .openingTunnel:
            return "tunneling"
        case .connected:
            return "connected"
        }
    }

    var connectionProgressDetail: String? {
        currentConnectionStep?.detail ?? connectionProgress?.terminalMessage
    }

    /// True when the server reports it needs the app's OpenAI account to be
    /// useful and no account is configured. Servers with an available opencode
    /// runtime are exempt: opencode holds its own credentials on the server
    /// (its configured provider), so the app's OpenAI sign-in isn't required
    /// to use it.
    var needsAppOpenaiSignIn: Bool {
        guard transportState == .connected, requiresOpenaiAuth, account == nil else { return false }
        let opencodeAvailable = agentRuntimes.contains { $0.kind == "opencode" && $0.available }
        return !opencodeAvailable
    }

    var statusLabel: String {
        if let connectionProgressLabel {
            return connectionProgressLabel
        }
        if needsAppOpenaiSignIn {
            return "Sign in required"
        }
        return transportState.displayLabel
    }

    var statusColor: Color {
        if currentConnectionStep?.state == .failed {
            return .red
        }
        if currentConnectionStep?.state == .awaitingUserInput {
            return .orange
        }
        if connectionProgressLabel != nil {
            return LitterTheme.accent
        }
        if needsAppOpenaiSignIn {
            return .orange
        }
        return transportState.accentColor
    }

    /// Stable mapping to the shared dot palette (green/orange/red). Used by
    /// the home server pills so connection state reads the same across themes.
    var statusDotState: StatusDotState {
        if currentConnectionStep?.state == .failed {
            return .error
        }
        if currentConnectionStep?.state == .awaitingUserInput {
            return .pending
        }
        if connectionProgressLabel != nil {
            return .pending
        }
        if needsAppOpenaiSignIn {
            return .pending
        }
        switch transportState {
        case .connected:
            return .ok
        case .connecting, .unresponsive:
            return .pending
        case .disconnected, .unknown:
            return .idle
        }
    }
}
