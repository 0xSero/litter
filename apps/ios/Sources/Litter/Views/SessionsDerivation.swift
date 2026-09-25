import Foundation

@MainActor
enum SessionsDerivation {
    private static let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func build(
        sessions: [AppSessionSummary],
        selectedServerFilterId: String?,
        showOnlyForks: Bool,
        selectedRuntimeKind: AgentRuntimeKind?,
        workspaceSortMode: WorkspaceSortMode,
        searchQuery: String,
        frozenMostRecentOrder: [ThreadKey]?
    ) -> SessionsDerivedData {
        let allThreads = sortThreads(
            sessions,
            workspaceSortMode: workspaceSortMode,
            frozenMostRecentOrder: frozenMostRecentOrder
        )

        var threadsByServerAndId: [String: [String: AppSessionSummary]] = [:]
        var childrenByServerAndParentId: [String: [String: [AppSessionSummary]]] = [:]
        var parentIdByThreadKey: [ThreadKey: String] = [:]

        for thread in allThreads {
            threadsByServerAndId[thread.serverId, default: [:]][thread.threadId] = thread
            if let parentId = sanitizedLineageId(thread.parentThreadId) {
                parentIdByThreadKey[thread.key] = parentId
                childrenByServerAndParentId[thread.serverId, default: [:]][parentId, default: []].append(thread)
            }
        }

        let sortedChildrenByServerAndParentId = childrenByServerAndParentId.mapValues { parentMap in
            parentMap.mapValues { children in
                children.sorted { $0.updatedAtDate > $1.updatedAtDate }
            }
        }

        var parentByKey: [ThreadKey: AppSessionSummary] = [:]
        var childrenByKey: [ThreadKey: [AppSessionSummary]] = [:]

        for thread in allThreads {
            let serverThreads = threadsByServerAndId[thread.serverId] ?? [:]
            if let parentId = parentIdByThreadKey[thread.key],
               let parent = serverThreads[parentId] {
                parentByKey[thread.key] = parent
            }
            childrenByKey[thread.key] = sortedChildrenByServerAndParentId[thread.serverId]?[thread.threadId] ?? []
        }

        let filteredThreads = allThreads.filter { thread in
            if let selectedServerFilterId, thread.serverId != selectedServerFilterId {
                return false
            }
            if showOnlyForks && !thread.isFork {
                return false
            }
            if let selectedRuntimeKind, thread.agentRuntimeKind != selectedRuntimeKind {
                return false
            }
            if searchQuery.isEmpty {
                return true
            }
            let parentTitle = parentByKey[thread.key]?.sessionTitle ?? ""
            return thread.sessionTitle.localizedCaseInsensitiveContains(searchQuery) ||
                thread.cwd.localizedCaseInsensitiveContains(searchQuery) ||
                thread.serverDisplayName.localizedCaseInsensitiveContains(searchQuery) ||
                thread.modelProvider.localizedCaseInsensitiveContains(searchQuery) ||
                parentTitle.localizedCaseInsensitiveContains(searchQuery) ||
                (thread.agentDisplayLabel?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }

        let groupedByWorkspace = Dictionary(grouping: filteredThreads) { workspaceGroupID(for: $0) }
        let workspaceGroups = groupedByWorkspace.compactMap { groupID, threads -> WorkspaceSessionGroup? in
            let sortedThreads = sortThreads(
                threads,
                workspaceSortMode: workspaceSortMode,
                frozenMostRecentOrder: frozenMostRecentOrder
            )
            guard let first = sortedThreads.first else { return nil }
            let workspacePath = normalizedWorkspacePath(first.cwd)
            return WorkspaceSessionGroup(
                id: groupID,
                serverId: first.serverId,
                serverName: first.serverDisplayName,
                serverHost: first.serverHost,
                workspacePath: workspacePath,
                workspaceTitle: workspaceTitle(for: workspacePath),
                latestUpdatedAt: first.updatedAtDate,
                threads: sortedThreads,
                treeRoots: buildSessionTree(for: sortedThreads, parentByKey: parentByKey)
            )
        }

        let sortedWorkspaceGroups = sortWorkspaceGroups(workspaceGroups, by: workspaceSortMode)
        let workspaceSections = workspaceSections(for: sortedWorkspaceGroups, sortMode: workspaceSortMode)
        let workspaceGroupIDs = sortedWorkspaceGroups.map(\.id)
        let workspaceGroupIDByThreadKey = Dictionary(uniqueKeysWithValues: filteredThreads.map {
            ($0.key, workspaceGroupID(for: $0))
        })

        return SessionsDerivedData(
            allThreads: allThreads,
            allThreadKeys: allThreads.map(\.key),
            filteredThreads: filteredThreads,
            filteredThreadKeys: filteredThreads.map(\.key),
            workspaceSections: workspaceSections,
            workspaceGroupIDs: workspaceGroupIDs,
            workspaceGroupIDByThreadKey: workspaceGroupIDByThreadKey,
            parentByKey: parentByKey,
            childrenByKey: childrenByKey
        )
    }

    private static func sortThreads(
        _ threads: [AppSessionSummary],
        workspaceSortMode: WorkspaceSortMode,
        frozenMostRecentOrder: [ThreadKey]?
    ) -> [AppSessionSummary] {
        guard workspaceSortMode == .mostRecent,
              let frozenMostRecentOrder,
              !frozenMostRecentOrder.isEmpty else {
            return threads.sorted { $0.updatedAtDate > $1.updatedAtDate }
        }

        let positions = Dictionary(uniqueKeysWithValues: frozenMostRecentOrder.enumerated().map { ($1, $0) })
        return threads.sorted { lhs, rhs in
            let lhsPosition = positions[lhs.key]
            let rhsPosition = positions[rhs.key]

            switch (lhsPosition, rhsPosition) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.updatedAtDate != rhs.updatedAtDate {
                    return lhs.updatedAtDate > rhs.updatedAtDate
                }
                return lhs.threadId.localizedCaseInsensitiveCompare(rhs.threadId) == .orderedAscending
            }
        }
    }

    private static func sortWorkspaceGroups(
        _ groups: [WorkspaceSessionGroup],
        by sortMode: WorkspaceSortMode
    ) -> [WorkspaceSessionGroup] {
        groups.sorted { lhs, rhs in
            switch sortMode {
            case .mostRecent:
                if lhs.latestUpdatedAt != rhs.latestUpdatedAt {
                    return lhs.latestUpdatedAt > rhs.latestUpdatedAt
                }
                return lhs.workspaceTitle.localizedCaseInsensitiveCompare(rhs.workspaceTitle) == .orderedAscending
            case .name:
                let titleOrder = lhs.workspaceTitle.localizedCaseInsensitiveCompare(rhs.workspaceTitle)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                let pathOrder = lhs.workspacePath.localizedCaseInsensitiveCompare(rhs.workspacePath)
                if pathOrder != .orderedSame {
                    return pathOrder == .orderedAscending
                }
                let serverOrder = lhs.serverName.localizedCaseInsensitiveCompare(rhs.serverName)
                if serverOrder != .orderedSame {
                    return serverOrder == .orderedAscending
                }
                return lhs.latestUpdatedAt > rhs.latestUpdatedAt
            case .date:
                if lhs.latestUpdatedAt != rhs.latestUpdatedAt {
                    return lhs.latestUpdatedAt > rhs.latestUpdatedAt
                }
                let titleOrder = lhs.workspaceTitle.localizedCaseInsensitiveCompare(rhs.workspaceTitle)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                let pathOrder = lhs.workspacePath.localizedCaseInsensitiveCompare(rhs.workspacePath)
                if pathOrder != .orderedSame {
                    return pathOrder == .orderedAscending
                }
                return lhs.serverName.localizedCaseInsensitiveCompare(rhs.serverName) == .orderedAscending
            }
        }
    }

    private static func workspaceSections(
        for groups: [WorkspaceSessionGroup],
        sortMode: WorkspaceSortMode
    ) -> [WorkspaceGroupSection] {
        guard sortMode == .date else {
            guard !groups.isEmpty else { return [] }
            return [WorkspaceGroupSection(id: "all", title: nil, groups: groups)]
        }

        let calendar = Calendar.current
        var groupsByDay: [Date: [WorkspaceSessionGroup]] = [:]
        for group in groups {
            let dayStart = calendar.startOfDay(for: group.latestUpdatedAt)
            groupsByDay[dayStart, default: []].append(group)
        }

        return groupsByDay.keys
            .sorted(by: >)
            .map { dayStart in
                WorkspaceGroupSection(
                    id: "day-\(Int(dayStart.timeIntervalSince1970))",
                    title: workspaceDateSectionLabel(for: dayStart),
                    groups: groupsByDay[dayStart] ?? []
                )
            }
    }

    private static func workspaceDateSectionLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let nowStart = calendar.startOfDay(for: Date())
        let dayDelta = max(calendar.dateComponents([.day], from: dayStart, to: nowStart).day ?? 0, 0)

        switch dayDelta {
        case 0:
            return "Today"
        case 1:
            return "Yesterday"
        case 2 ... 6:
            return "\(dayDelta) days ago"
        default:
            return absoluteDateFormatter.string(from: dayStart)
        }
    }

    private static func buildSessionTree(
        for threads: [AppSessionSummary],
        parentByKey: [ThreadKey: AppSessionSummary]
    ) -> [SessionTreeNode] {
        let threadsByKey = Dictionary(uniqueKeysWithValues: threads.map { ($0.key, $0) })
        var childrenByParentKey: [ThreadKey: [AppSessionSummary]] = [:]

        for thread in threads {
            guard let parent = parentByKey[thread.key], threadsByKey[parent.key] != nil else { continue }
            childrenByParentKey[parent.key, default: []].append(thread)
        }
        childrenByParentKey = childrenByParentKey.mapValues { children in
            children.sorted { $0.updatedAtDate > $1.updatedAtDate }
        }

        var emitted: Set<ThreadKey> = []

        func makeNode(_ thread: AppSessionSummary, path: inout Set<ThreadKey>) -> SessionTreeNode {
            path.insert(thread.key)
            let children = (childrenByParentKey[thread.key] ?? []).compactMap { child -> SessionTreeNode? in
                guard !path.contains(child.key), emitted.insert(child.key).inserted else { return nil }
                return makeNode(child, path: &path)
            }
            path.remove(thread.key)
            return SessionTreeNode(thread: thread, children: children)
        }

        let roots = threads.filter { thread in
            guard let parent = parentByKey[thread.key] else { return true }
            return threadsByKey[parent.key] == nil
        }

        var treeRoots: [SessionTreeNode] = []
        for root in roots {
            guard emitted.insert(root.key).inserted else { continue }
            var path: Set<ThreadKey> = []
            treeRoots.append(makeNode(root, path: &path))
        }

        for thread in threads where !emitted.contains(thread.key) {
            emitted.insert(thread.key)
            var path: Set<ThreadKey> = []
            treeRoots.append(makeNode(thread, path: &path))
        }

        return treeRoots
    }

    private static func sanitizedLineageId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
