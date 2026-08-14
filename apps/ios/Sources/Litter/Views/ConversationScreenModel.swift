import Foundation
import Observation
import UIKit

struct ConversationTranscriptSnapshot: Equatable {
    var items: [ConversationItem]
    var threadStatus: ConversationStatus
    var agentDirectoryVersion: UInt64
    var renderDigest: Int

    static let empty = ConversationTranscriptSnapshot(
        items: [],
        threadStatus: .ready,
        agentDirectoryVersion: 0,
        renderDigest: 0
    )

    static func == (lhs: ConversationTranscriptSnapshot, rhs: ConversationTranscriptSnapshot) -> Bool {
        lhs.threadStatus == rhs.threadStatus
            && lhs.agentDirectoryVersion == rhs.agentDirectoryVersion
            && lhs.renderDigest == rhs.renderDigest
    }
}

struct ConversationComposerSnapshot: Equatable {
    var threadKey: ThreadKey
    var collaborationMode: AppModeKind
    var activePlanProgress: AppPlanProgressSnapshot?
    var pendingPlanImplementationPrompt: AppPlanImplementationPromptSnapshot?
    var pendingUserInputRequest: PendingUserInputRequest?
    var activeTaskSummary: ConversationActiveTaskSummary?
    var queuedFollowUps: [AppQueuedFollowUpPreview]
    var composerPrefillRequest: AppModel.ComposerPrefillRequest?
    var goal: AppThreadGoal?
    var activeTurnId: String?
    var isTurnActive: Bool
    var threadPreview: String
    var threadModel: String
    var threadReasoningEffort: String?
    var modelContextWindow: Int64?
    var contextTokensUsed: Int64?
    var rateLimits: RateLimitSnapshot?
    var availableModels: [ModelInfo]
    var isConnected: Bool

    static let empty = ConversationComposerSnapshot(
        threadKey: ThreadKey(serverId: "", threadId: ""),
        collaborationMode: .`default`,
        activePlanProgress: nil,
        pendingPlanImplementationPrompt: nil,
        pendingUserInputRequest: nil,
        activeTaskSummary: nil,
        queuedFollowUps: [],
        composerPrefillRequest: nil,
        goal: nil,
        activeTurnId: nil,
        isTurnActive: false,
        threadPreview: "",
        threadModel: "",
        threadReasoningEffort: nil,
        modelContextWindow: nil,
        contextTokensUsed: nil,
        rateLimits: nil,
        availableModels: [],
        isConnected: false
    )
}

struct ConversationActiveTaskSummary: Equatable {
    var progressLabel: String
    var title: String
    var detail: String
}

struct MinigameContent: Equatable {
    let html: String
    let title: String
    let width: CGFloat
    let height: CGFloat
}

enum MinigameOverlayState: Equatable {
    case idle
    case loading
    case shown(MinigameContent)
    case failed(String)
}

@MainActor
@Observable
final class ConversationScreenModel {
    private(set) var transcript: ConversationTranscriptSnapshot = .empty
    private(set) var pinnedContextItems: [ConversationItem] = []
    private(set) var composer: ConversationComposerSnapshot = .empty
    private(set) var followScrollToken = 0
    private(set) var minigameOverlay: MinigameOverlayState = .idle
    /// Live composer draft. Lifted out of `ConversationInputBar` so it
    /// survives view teardown when `ConversationDestinationScreen` flips
    /// through its `if let conversationThread` branch during foreground
    /// refresh — otherwise typed-but-unsent text and pasted attachments
    /// vanish on app switch.
    var composerInputText: String = ""
    var composerAttachedImage: UIImage?

    @ObservationIgnored private var thread: AppThreadSnapshot?
    @ObservationIgnored private var appModel: AppModel?
    @ObservationIgnored private var agentDirectoryVersion: UInt64 = 0
    @ObservationIgnored private var cachedConversationItemProjections: [String: CachedConversationItemProjection] = [:]
    @ObservationIgnored private var cachedHydratedConversationItems: [HydratedConversationItem] = []
    @ObservationIgnored private var cachedProjectedConversationItems: [ConversationItem] = []
    @ObservationIgnored private var transcriptRevision: Int = 0
    @ObservationIgnored private var minigameTask: Task<Void, Never>?

    func bind(
        thread: AppThreadSnapshot,
        appModel: AppModel,
        agentDirectoryVersion: UInt64
    ) {
        let threadChanged =
            self.thread?.key != thread.key ||
            self.appModel !== appModel

        self.thread = thread
        self.appModel = appModel
        self.agentDirectoryVersion = agentDirectoryVersion

        if threadChanged {
            followScrollToken = 0
            cachedHydratedConversationItems = []
            cachedConversationItemProjections = [:]
            cachedProjectedConversationItems = []
            transcriptRevision = 0
            minigameTask?.cancel()
            minigameTask = nil
            minigameOverlay = .idle
            composerInputText = ""
            composerAttachedImage = nil
        }

        refreshState()
    }

    private func refreshState() {
        #if DEBUG
        let refreshSignpostID = PerfAttribution.begin("RefreshState"); defer { PerfAttribution.end("RefreshState", refreshSignpostID) }
        #endif
        guard let thread, let appModel else {
            transcript = .empty
            pinnedContextItems = []
            composer = .empty
            followScrollToken = 0
            return
        }

        let currentTranscript = transcript

        let projection = projectConversationItems(from: thread.hydratedConversationItems)
        let items = projection.items
        let threadStatus = conversationStatus(from: thread)
        let activeTurnId: String?
        if let value = thread.activeTurnId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            activeTurnId = value
        } else {
            activeTurnId = nil
        }
        let hasTurnInFlight = activeTurnId != nil || thread.info.status == .active
        let pendingUserInputRequest = appModel.snapshot?.pendingUserInputs.first {
            $0.isRelevant(to: thread.key)
        }
        let activeTaskSummary = items.latestActiveTaskSummary
        let composerPrefillRequest = appModel.composerPrefillRequest.flatMap { request in
            request.threadKey == thread.key ? request : nil
        }
        let composerSnapshot = ConversationComposerSnapshot(
            threadKey: thread.key,
            collaborationMode: thread.collaborationMode,
            activePlanProgress: thread.activePlanProgress,
            pendingPlanImplementationPrompt: thread.pendingPlanImplementationPrompt,
            pendingUserInputRequest: pendingUserInputRequest,
            activeTaskSummary: activeTaskSummary,
            queuedFollowUps: thread.queuedFollowUps,
            composerPrefillRequest: composerPrefillRequest,
            goal: thread.goal,
            activeTurnId: activeTurnId,
            isTurnActive: activeTurnId != nil,
            threadPreview: thread.resolvedPreview,
            threadModel: thread.resolvedModel,
            threadReasoningEffort: thread.reasoningEffort,
            modelContextWindow: thread.modelContextWindow.map(Int64.init),
            contextTokensUsed: thread.contextTokensUsed.map(Int64.init),
            rateLimits: appModel.rateLimits(
                forServer: thread.key.serverId,
                runtime: thread.agentRuntimeKind
            ),
            availableModels: appModel.availableModels(for: thread.key.serverId),
            isConnected: appModel.snapshot?.serverSnapshot(for: thread.key.serverId)?.isConnected ?? false
        )

        let transcriptChanged =
            projection.didChange
            || currentTranscript.threadStatus != threadStatus
            || currentTranscript.agentDirectoryVersion != agentDirectoryVersion
        if transcriptChanged {
            transcriptRevision &+= 1
            if hasTurnInFlight {
                LLog.trace("streaming", "transcript changed during turn", fields: [
                    "projDidChange": projection.didChange,
                    "itemCount": items.count,
                    "revision": transcriptRevision,
                    "threadStatus": String(describing: threadStatus)
                ])
            }
        }
        let nextTranscript = ConversationTranscriptSnapshot(
            items: transcriptChanged ? items : currentTranscript.items,
            threadStatus: threadStatus,
            agentDirectoryVersion: agentDirectoryVersion,
            renderDigest: transcriptChanged ? transcriptRevision : currentTranscript.renderDigest
        )
        var nextFollowScrollToken = followScrollToken
        if hasTurnInFlight,
           projection.didChange {
            nextFollowScrollToken &+= 1
        }
        if transcript != nextTranscript {
            transcript = nextTranscript
            pinnedContextItems = items
        }
        if composer != composerSnapshot {
            composer = composerSnapshot
        }
        if followScrollToken != nextFollowScrollToken {
            followScrollToken = nextFollowScrollToken
        }
    }
}

extension ConversationScreenModel {
    func requestMinigame() {
        guard ExperimentalFeatures.shared.isEnabled(.thinkingMinigame) else { return }
        guard minigameOverlay == .idle else { return }
        guard let thread, let appModel else { return }

        var lastUser: String?
        var lastAssistant: String?
        for item in transcript.items.reversed() {
            switch item.content {
            case .user(let data) where lastUser == nil:
                lastUser = data.text
            case .assistant(let data) where lastAssistant == nil:
                lastAssistant = data.text
            default:
                break
            }
            if lastUser != nil && lastAssistant != nil { break }
        }

        minigameOverlay = .loading
        minigameTask?.cancel()

        let request = AppMinigameRequest(
            serverId: thread.key.serverId,
            parentThreadId: thread.key.threadId,
            lastUserMessage: lastUser,
            lastAssistantMessage: lastAssistant
        )
        let client = appModel.client

        minigameTask = Task { @MainActor [weak self] in
            do {
                let result = try await client.startMinigame(request: request)
                guard let self else { return }
                if Task.isCancelled { return }
                self.minigameOverlay = .shown(MinigameContent(
                    html: result.widgetHtml,
                    title: result.title,
                    width: CGFloat(result.width),
                    height: CGFloat(result.height)
                ))
            } catch {
                guard let self else { return }
                if Task.isCancelled { return }
                self.minigameOverlay = .failed(String(describing: error))
            }
        }
    }

    func dismissMinigame() {
        minigameTask?.cancel()
        minigameTask = nil
        minigameOverlay = .idle
    }
}

private struct CachedConversationItemProjection {
    let hydratedItem: HydratedConversationItem
    let conversationItem: ConversationItem
}

private struct ProjectedConversationItemsResult {
    let items: [ConversationItem]
    let didChange: Bool
}

private extension ConversationScreenModel {
    func projectConversationItems(from hydratedItems: [HydratedConversationItem]) -> ProjectedConversationItemsResult {
        #if DEBUG
        let projectSignpostID = PerfAttribution.begin("ProjectItems"); defer { PerfAttribution.end("ProjectItems", projectSignpostID) }
        #endif
        let previousHydratedItems = cachedHydratedConversationItems
        if previousHydratedItems == hydratedItems {
            return ProjectedConversationItemsResult(
                items: cachedProjectedConversationItems,
                didChange: false
            )
        }

        let prefixCount = commonPrefixCount(
            lhs: previousHydratedItems,
            rhs: hydratedItems
        )
        let suffixCount = commonSuffixCount(
            lhs: previousHydratedItems,
            rhs: hydratedItems,
            excludingPrefix: prefixCount
        )

        var nextCache: [String: CachedConversationItemProjection] = [:]
        nextCache.reserveCapacity(hydratedItems.count)

        var projectedItems: [ConversationItem] = []
        projectedItems.reserveCapacity(hydratedItems.count)

        if prefixCount > 0, cachedProjectedConversationItems.count >= prefixCount {
            for index in 0..<prefixCount {
                let hydratedItem = hydratedItems[index]
                let conversationItem = cachedProjectedConversationItems[index]
                projectedItems.append(conversationItem)
                nextCache[hydratedItem.id] = CachedConversationItemProjection(
                    hydratedItem: hydratedItem,
                    conversationItem: conversationItem
                )
            }
        }

        let changedUpperBound = hydratedItems.count - suffixCount
        if prefixCount < changedUpperBound {
            for index in prefixCount..<changedUpperBound {
                let hydratedItem = hydratedItems[index]
                let conversationItem: ConversationItem
                if let cached = cachedConversationItemProjections[hydratedItem.id],
                   cached.hydratedItem == hydratedItem {
                    conversationItem = cached.conversationItem
                } else {
                    conversationItem = hydratedItem.conversationItem
                }

                projectedItems.append(conversationItem)
                nextCache[hydratedItem.id] = CachedConversationItemProjection(
                    hydratedItem: hydratedItem,
                    conversationItem: conversationItem
                )
            }
        }

        if suffixCount > 0, cachedProjectedConversationItems.count >= prefixCount + suffixCount {
            let oldSuffixStart = cachedProjectedConversationItems.count - suffixCount
            let newSuffixStart = hydratedItems.count - suffixCount
            for offset in 0..<suffixCount {
                let hydratedItem = hydratedItems[newSuffixStart + offset]
                let conversationItem = cachedProjectedConversationItems[oldSuffixStart + offset]
                projectedItems.append(conversationItem)
                nextCache[hydratedItem.id] = CachedConversationItemProjection(
                    hydratedItem: hydratedItem,
                    conversationItem: conversationItem
                )
            }
        }

        cachedHydratedConversationItems = hydratedItems
        cachedConversationItemProjections = nextCache
        cachedProjectedConversationItems = projectedItems
        return ProjectedConversationItemsResult(items: projectedItems, didChange: true)
    }

    func commonPrefixCount(
        lhs: [HydratedConversationItem],
        rhs: [HydratedConversationItem]
    ) -> Int {
        let maxCount = min(lhs.count, rhs.count)
        var index = 0
        while index < maxCount, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    func commonSuffixCount(
        lhs: [HydratedConversationItem],
        rhs: [HydratedConversationItem],
        excludingPrefix prefixCount: Int
    ) -> Int {
        let maxCount = min(lhs.count, rhs.count) - prefixCount
        guard maxCount > 0 else { return 0 }

        var suffixCount = 0
        while suffixCount < maxCount {
            let lhsIndex = lhs.index(lhs.endIndex, offsetBy: -suffixCount - 1)
            let rhsIndex = rhs.index(rhs.endIndex, offsetBy: -suffixCount - 1)
            guard lhs[lhsIndex] == rhs[rhsIndex] else { break }
            suffixCount += 1
        }
        return suffixCount
    }
}

private func conversationStatus(from thread: AppThreadSnapshot) -> ConversationStatus {
    switch thread.info.status {
    case .active:
        return .thinking
    case .systemError:
        return .error("Session error")
    case .notLoaded:
        return .connecting
    case .idle:
        return .ready
    }
}

private extension Array where Element == ConversationItem {
    var latestActiveTaskSummary: ConversationActiveTaskSummary? {
        for item in reversed() {
            guard case .todoList(let data) = item.content else { continue }
            let total = data.steps.count
            guard total > 0 else { continue }

            let activeSteps = data.steps.filter { $0.status != .completed }
            guard !activeSteps.isEmpty else { continue }

            let completed = data.completedCount
            let focusStep = data.steps.first(where: { $0.status == .inProgress })
                ?? data.steps.first(where: { $0.status == .pending })
                ?? activeSteps.first
            let detail = focusStep?.step.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title: String
            if activeSteps.count == 1 {
                title = "1 active task"
            } else {
                title = "\(activeSteps.count) active tasks"
            }

            return ConversationActiveTaskSummary(
                progressLabel: "\(completed)/\(total)",
                title: title,
                detail: detail.isEmpty ? title : detail
            )
        }

        return nil
    }
}

#if DEBUG
extension ConversationScreenModel {
    func _testProjectConversationItems(
        from hydratedItems: [HydratedConversationItem]
    ) -> [ConversationItem] {
        projectConversationItems(from: hydratedItems).items
    }
}
#endif
