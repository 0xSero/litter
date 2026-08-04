import Foundation

extension AppSessionSummary: Identifiable {
    public var id: ThreadKey { key }
    var serverId: String { key.serverId }
    var threadId: String { key.threadId }
    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let trimmedPreview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPreview.isEmpty {
            return trimmedPreview
        }

        return "Untitled session"
    }

    var sessionTitle: String {
        displayTitle
    }

    var sessionModelLabel: String? {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return nil }
        if let agentLabel = agentDisplayLabel {
            return "\(trimmedModel) (\(agentLabel))"
        }
        return trimmedModel
    }
    
    var updatedAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAt ?? 0))
    }

    var subagentStatus: AppSubagentStatus {
        agentStatus
    }
}

enum WorkspaceSortMode: String, CaseIterable, Identifiable {
    case mostRecent
    case name
    case date

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostRecent:
            return "Most Recent"
        case .name:
            return "Name"
        case .date:
            return "Date"
        }
    }
}

struct WorkspaceSessionGroup: Identifiable, Equatable {
    let id: String
    let serverId: String
    let serverName: String
    let serverHost: String
    let workspacePath: String
    let workspaceTitle: String
    let latestUpdatedAt: Date
    let threads: [AppSessionSummary]
    let treeRoots: [SessionTreeNode]
}

struct WorkspaceGroupSection: Identifiable, Equatable {
    let id: String
    let title: String?
    let groups: [WorkspaceSessionGroup]
}

struct SessionTreeNode: Identifiable, Equatable {
    let thread: AppSessionSummary
    let children: [SessionTreeNode]

    var id: ThreadKey { thread.key }
}

struct SessionsDerivedData: Equatable {
    static let empty = SessionsDerivedData(
        allThreads: [],
        allThreadKeys: [],
        filteredThreads: [],
        filteredThreadKeys: [],
        workspaceSections: [],
        workspaceGroupIDs: [],
        workspaceGroupIDByThreadKey: [:],
        parentByKey: [:],
        siblingsByKey: [:],
        childrenByKey: [:]
    )

    let allThreads: [AppSessionSummary]
    let allThreadKeys: [ThreadKey]
    let filteredThreads: [AppSessionSummary]
    let filteredThreadKeys: [ThreadKey]
    let workspaceSections: [WorkspaceGroupSection]
    let workspaceGroupIDs: [String]
    let workspaceGroupIDByThreadKey: [ThreadKey: String]
    let parentByKey: [ThreadKey: AppSessionSummary]
    let siblingsByKey: [ThreadKey: [AppSessionSummary]]
    let childrenByKey: [ThreadKey: [AppSessionSummary]]
}

func normalizedWorkspacePath(_ raw: String) -> String {
    var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.isEmpty {
        return "/"
    }
    path = path.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
    while path.count > 1 && path.hasSuffix("/") {
        path.removeLast()
    }
    return path.isEmpty ? "/" : path
}

@MainActor
func workspaceGroupID(for thread: AppSessionSummary) -> String {
    "\(thread.serverId)::\(normalizedWorkspacePath(thread.cwd))"
}

func workspaceTitle(for workspacePath: String) -> String {
    if workspacePath == "/" {
        return "/"
    }
    let name = URL(fileURLWithPath: workspacePath).lastPathComponent
    return name.isEmpty ? workspacePath : name
}
