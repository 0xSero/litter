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

    var statusLabel: String {
        if let connectionProgressLabel {
            return connectionProgressLabel
        }
        if transportState == .connected, requiresOpenaiAuth, account == nil {
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
        if transportState == .connected, requiresOpenaiAuth, account == nil {
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
        if transportState == .connected, requiresOpenaiAuth, account == nil {
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
