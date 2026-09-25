import SwiftUI
import UIKit

/// Shared limits for composer attachments, so the home composer, the
/// in-conversation composer and the photo pickers cannot drift apart.
enum ComposerAttachmentLimits {
    /// Maximum number of images that can ride along with a single turn.
    static let maxImages = 10
}

struct ConversationComposerContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let attachedImages: [UIImage]
    let attachedFiles: [ComposerFileAttachment]
    let collaborationMode: AppModeKind
    let activePlanProgress: AppPlanProgressSnapshot?
    let pendingUserInputRequest: PendingUserInputRequest?
    let hasPendingPlanImplementation: Bool
    let activeTaskSummary: ConversationActiveTaskSummary?
    let queuedFollowUps: [AppQueuedFollowUpPreview]
    let pluginMentions: [PluginMentionSelection]
    let goal: AppThreadGoal?
    let goalActions: GoalCardActions
    let rateLimits: RateLimitSnapshot?
    let contextPercent: Int64?
    let isTurnActive: Bool
    let showModeChip: Bool
    let modelLabel: String?
    let reasoningLabel: String?
    let voiceManager: VoiceTranscriptionManager
    let allowsVoiceInput: Bool
    @Binding var showAttachMenu: Bool
    let onClearAttachment: () -> Void
    let onRemoveImage: (Int) -> Void
    let onRemoveFileAttachment: (ComposerFileAttachment) -> Void
    let onRespondToPendingUserInput: ([String: [String]]) -> Void
    let onDismissPendingUserInput: () -> Void
    let onImplementPlan: () -> Void
    let onDismissPlanImplementation: () -> Void
    let onSteerQueuedFollowUp: (AppQueuedFollowUpPreview) -> Void
    let onDeleteQueuedFollowUp: (AppQueuedFollowUpPreview) -> Void
    let onRemovePluginMention: (PluginMentionSelection) -> Void
    let onPasteImage: (UIImage) -> Void
    let onOpenModePicker: () -> Void
    let onOpenModelPicker: () -> Void
    let onSendText: () -> Void
    let onStopRecording: () -> Void
    let onStartRecording: () -> Void
    let onInterrupt: () -> Void
    @Binding var inputText: String
    @Binding var isComposerFocused: Bool
    @Binding var composerSelectionRange: NSRange

    init(
        attachedImages: [UIImage] = [],
        attachedFiles: [ComposerFileAttachment] = [],
        collaborationMode: AppModeKind,
        activePlanProgress: AppPlanProgressSnapshot?,
        pendingUserInputRequest: PendingUserInputRequest?,
        hasPendingPlanImplementation: Bool = false,
        activeTaskSummary: ConversationActiveTaskSummary?,
        queuedFollowUps: [AppQueuedFollowUpPreview],
        pluginMentions: [PluginMentionSelection] = [],
        goal: AppThreadGoal? = nil,
        goalActions: GoalCardActions = .noop,
        rateLimits: RateLimitSnapshot?,
        contextPercent: Int64?,
        isTurnActive: Bool,
        showModeChip: Bool = true,
        modelLabel: String? = nil,
        reasoningLabel: String? = nil,
        voiceManager: VoiceTranscriptionManager,
        allowsVoiceInput: Bool = true,
        showAttachMenu: Binding<Bool>,
        onClearAttachment: @escaping () -> Void,
        onRemoveImage: @escaping (Int) -> Void = { _ in },
        onRemoveFileAttachment: @escaping (ComposerFileAttachment) -> Void = { _ in },
        onRespondToPendingUserInput: @escaping ([String: [String]]) -> Void,
        onDismissPendingUserInput: @escaping () -> Void = {},
        onImplementPlan: @escaping () -> Void = {},
        onDismissPlanImplementation: @escaping () -> Void = {},
        onSteerQueuedFollowUp: @escaping (AppQueuedFollowUpPreview) -> Void,
        onDeleteQueuedFollowUp: @escaping (AppQueuedFollowUpPreview) -> Void,
        onRemovePluginMention: @escaping (PluginMentionSelection) -> Void = { _ in },
        onPasteImage: @escaping (UIImage) -> Void,
        onOpenModePicker: @escaping () -> Void,
        onOpenModelPicker: @escaping () -> Void = {},
        onSendText: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        inputText: Binding<String>,
        isComposerFocused: Binding<Bool>,
        composerSelectionRange: Binding<NSRange> = .constant(NSRange(location: 0, length: 0))
    ) {
        self.attachedImages = attachedImages
        self.attachedFiles = attachedFiles
        self.collaborationMode = collaborationMode
        self.activePlanProgress = activePlanProgress
        self.pendingUserInputRequest = pendingUserInputRequest
        self.hasPendingPlanImplementation = hasPendingPlanImplementation
        self.activeTaskSummary = activeTaskSummary
        self.queuedFollowUps = queuedFollowUps
        self.pluginMentions = pluginMentions
        self.goal = goal
        self.goalActions = goalActions
        self.rateLimits = rateLimits
        self.contextPercent = contextPercent
        self.isTurnActive = isTurnActive
        self.showModeChip = showModeChip
        self.modelLabel = modelLabel
        self.reasoningLabel = reasoningLabel
        self.voiceManager = voiceManager
        self.allowsVoiceInput = allowsVoiceInput
        _showAttachMenu = showAttachMenu
        self.onClearAttachment = onClearAttachment
        self.onRemoveImage = onRemoveImage
        self.onRemoveFileAttachment = onRemoveFileAttachment
        self.onRespondToPendingUserInput = onRespondToPendingUserInput
        self.onDismissPendingUserInput = onDismissPendingUserInput
        self.onImplementPlan = onImplementPlan
        self.onDismissPlanImplementation = onDismissPlanImplementation
        self.onSteerQueuedFollowUp = onSteerQueuedFollowUp
        self.onDeleteQueuedFollowUp = onDeleteQueuedFollowUp
        self.onRemovePluginMention = onRemovePluginMention
        self.onPasteImage = onPasteImage
        self.onOpenModePicker = onOpenModePicker
        self.onOpenModelPicker = onOpenModelPicker
        self.onSendText = onSendText
        self.onStopRecording = onStopRecording
        self.onStartRecording = onStartRecording
        self.onInterrupt = onInterrupt
        _inputText = inputText
        _isComposerFocused = isComposerFocused
        _composerSelectionRange = composerSelectionRange
    }

    var body: some View {
        VStack(spacing: 0) {
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedImages.indices, id: \.self) { index in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: attachedImages[index])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button(action: { onRemoveImage(index) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .litterFont(.body)
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.6)))
                                }
                                .offset(x: 4, y: -4)
                                .accessibilityLabel("Remove image \(index + 1)")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }

            if !attachedFiles.isEmpty {
                ConversationComposerFileChipStrip(
                    files: attachedFiles,
                    onRemove: onRemoveFileAttachment
                )
                .padding(.horizontal, 16)
                .padding(.top, attachedImages.isEmpty ? 8 : 6)
            }

            VStack(alignment: .trailing, spacing: 0) {
                if let goal {
                    ConversationComposerGoalRowView(goal: goal, actions: goalActions)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if let activePlanProgress {
                    ConversationComposerPlanProgressView(progress: activePlanProgress)
                        .id(activePlanProgress.turnId)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if let activeTaskSummary {
                    ConversationComposerActiveTaskRowView(summary: activeTaskSummary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if let pendingUserInputRequest {
                    PendingUserInputPromptView(
                        request: pendingUserInputRequest,
                        onSubmit: onRespondToPendingUserInput,
                        onDismiss: onDismissPendingUserInput
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                if hasPendingPlanImplementation {
                    PlanImplementationPromptView(
                        onImplement: onImplementPlan,
                        onDismiss: onDismissPlanImplementation
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                if !queuedFollowUps.isEmpty {
                    QueuedFollowUpsPreviewView(
                        previews: queuedFollowUps,
                        onSteer: onSteerQueuedFollowUp,
                        onDelete: onDeleteQueuedFollowUp
                    )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if !pluginMentions.isEmpty {
                    ConversationComposerPluginChipStrip(
                        plugins: pluginMentions,
                        onRemove: onRemovePluginMention
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }

                ConversationComposerEntryRowView(
                    showAttachMenu: $showAttachMenu,
                    inputText: $inputText,
                    isComposerFocused: $isComposerFocused,
                    composerSelectionRange: $composerSelectionRange,
                    voiceManager: voiceManager,
                    isTurnActive: isTurnActive,
                    hasAttachment: !attachedImages.isEmpty || !attachedFiles.isEmpty,
                    allowsVoiceInput: allowsVoiceInput,
                    modelLabel: modelLabel,
                    reasoningLabel: reasoningLabel,
                    collaborationMode: collaborationMode,
                    showModeChip: showModeChip,
                    onPasteImage: onPasteImage,
                    onOpenModelPicker: onOpenModelPicker,
                    onOpenModePicker: onOpenModePicker,
                    onSendText: onSendText,
                    onStopRecording: onStopRecording,
                    onStartRecording: onStartRecording,
                    onInterrupt: onInterrupt
                )

                ConversationComposerContextBarView(
                    rateLimits: rateLimits,
                    contextPercent: contextPercent
                )
            }
        }
        .frame(maxWidth: LitterPlatform.isRegularSurface(horizontalSizeClass: horizontalSizeClass) ? 760 : .infinity)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ConversationComposerFileChipStrip: View {
    let files: [ComposerFileAttachment]
    let onRemove: (ComposerFileAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files) { file in
                    HStack(spacing: LitterSpace.s) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.label)
                                .litterFont(size: 15)
                                .foregroundStyle(LitterTheme.textPrimary)
                                .lineLimit(1)
                            Text(file.path)
                                .litterMeta()
                                .lineLimit(1)
                        }
                        .frame(maxWidth: 180, alignment: .leading)
                        Button {
                            onRemove(file)
                        } label: {
                            Image(systemName: "xmark")
                                .litterFont(size: 13, weight: .semibold)
                                .foregroundStyle(LitterTheme.meta)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove file \(file.label)")
                    }
                    .padding(.leading, LitterSpace.m)
                    .padding(.vertical, LitterSpace.xs)
                    .background(
                        RoundedRectangle(cornerRadius: LitterRadius.raised, style: .continuous)
                            .fill(LitterTheme.raised)
                    )
                }
            }
        }
    }
}

private struct ConversationComposerPluginChipStrip: View {
    let plugins: [PluginMentionSelection]
    let onRemove: (PluginMentionSelection) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(plugins, id: \.path) { plugin in
                    HStack(spacing: LitterSpace.xs) {
                        Text(plugin.displayTitle)
                            .litterFont(size: 15)
                            .foregroundStyle(LitterTheme.textPrimary)
                            .lineLimit(1)
                        Button {
                            onRemove(plugin)
                        } label: {
                            Image(systemName: "xmark")
                                .litterFont(size: 13, weight: .semibold)
                                .foregroundStyle(LitterTheme.meta)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove plugin \(plugin.displayTitle)")
                    }
                    .padding(.leading, LitterSpace.m)
                    .background(
                        RoundedRectangle(cornerRadius: LitterRadius.raised, style: .continuous)
                            .fill(LitterTheme.raised)
                    )
                }
            }
        }
    }
}

struct ConversationComposerModeChip: View {
    let mode: AppModeKind
    let onTap: () -> Void

    private var label: String {
        switch mode {
        case .plan:
            return "Plan"
        case .`default`:
            return "Default"
        }
    }

    private var foreground: Color { LitterTheme.textPrimary }

    private var background: Color { LitterTheme.raised }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(label.lowercased())
                    .litterMonoFont(size: 13, weight: mode == .plan ? .semibold : .regular)
                Image(systemName: "chevron.up.chevron.down")
                    .litterFont(size: 11, weight: .semibold)
                    .foregroundStyle(LitterTheme.meta)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, LitterSpace.m)
            .frame(minHeight: 32)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mode: \(label)")
    }
}

private struct ConversationComposerPlanProgressView: View {
    let progress: AppPlanProgressSnapshot
    @State private var isExpanded = true

    private var completedCount: Int {
        progress.plan.filter { $0.status == .completed }.count
    }

    private var currentStepText: String {
        guard let step = currentStep?.step.trimmingCharacters(in: .whitespacesAndNewlines),
              !step.isEmpty else {
            return progress.plan.isEmpty ? "No plan task" : "Plan complete"
        }
        return step
    }

    private var currentStep: AppPlanStep? {
        progress.plan.first(where: { $0.status == .inProgress })
            ?? progress.plan.first(where: { $0.status == .pending })
            ?? progress.plan.last(where: { $0.status == .completed })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    headerContent
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse plan progress" : "Expand plan progress")

            if isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LitterSpace.m)
        .background(
            RoundedRectangle(cornerRadius: LitterRadius.raised, style: .continuous)
                .fill(LitterTheme.raised)
        )
    }

    private var headerContent: some View {
        Group {
            Text("plan · \(completedCount)/\(progress.plan.count)")
                .litterMeta()

            if !isExpanded {
                Text(currentStepText)
                    .litterFont(size: 15)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            } else {
                Spacer(minLength: 0)
            }

            Text(isExpanded ? "⌄" : "›")
                .litterMeta()
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let explanation = progress.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explanation.isEmpty {
            Text(explanation)
                .litterFont(size: 15)
                .foregroundStyle(LitterTheme.textSecondary)
        }

        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(progress.plan.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: LitterSpace.s) {
                    Text("\(index + 1).")
                        .litterMeta()
                    Text(step.step)
                        .litterFont(size: 15)
                        .foregroundStyle(step.status == .completed ? LitterTheme.textSecondary : LitterTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let word = statusWord(for: step.status) {
                        Text(word)
                            .litterMeta()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func statusWord(for status: AppPlanStepStatus) -> String? {
        switch status {
        case .completed: return "done"
        case .inProgress: return "working…"
        case .pending: return nil
        }
    }
}

struct GoalCardActions {
    var togglePause: () -> Void
    var markComplete: () -> Void
    var setObjective: (String) -> Void
    var setBudget: (Int64?) -> Void
    var clear: () -> Void

    static let noop = GoalCardActions(
        togglePause: {},
        markComplete: {},
        setObjective: { _ in },
        setBudget: { _ in },
        clear: {}
    )
}

private struct ConversationComposerGoalRowView: View {
    let goal: AppThreadGoal
    let actions: GoalCardActions

    @State private var showEditSheet = false
    @State private var showBudgetSheet = false
    @State private var showClearConfirm = false
    @State private var draftObjective = ""
    @State private var draftBudget = ""
    @State private var animatedProgress: Double = 0

    private let cornerRadius: CGFloat = LitterRadius.raised

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                statusPill

                Text(goal.objective)
                    .litterFont(size: 15)
                    .foregroundColor(LitterTheme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draftObjective = goal.objective
                        showEditSheet = true
                    }
                    .accessibilityHint("Tap to edit objective")

                overflowMenu
            }

            if let progress = budgetProgress {
                budgetGauge(progress: progress)
            }

            if hasUsageMetrics {
                usageMetricsRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GoalCardChromeModifier(statusTint: statusTint, cornerRadius: cornerRadius))
        .alert("Edit Goal", isPresented: $showEditSheet) {
            TextField("Objective", text: $draftObjective, axis: .vertical)
            Button("Save") {
                let trimmed = draftObjective.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { actions.setObjective(trimmed) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Token Budget", isPresented: $showBudgetSheet) {
            TextField("e.g. 50000", text: $draftBudget)
                .keyboardType(.numberPad)
            Button("Save") {
                let trimmed = draftBudget.trimmingCharacters(in: .whitespaces)
                if let value = Int64(trimmed), value > 0 {
                    actions.setBudget(value)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Set a token cap for this goal. The agent will pause when the cap is reached.")
        }
        .confirmationDialog(
            "Clear this goal?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Goal", role: .destructive) { actions.clear() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            animatedProgress = budgetProgress ?? 0
        }
        .onChange(of: budgetProgress ?? 0) { _, new in
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                animatedProgress = new
            }
        }
    }

    private var statusPill: some View {
        Button(action: { if canTogglePause { actions.togglePause() } }) {
            Text("goal · \(statusLabel)")
                .litterMeta(statusTint)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canTogglePause)
        .accessibilityLabel(pauseToggleAccessibilityLabel)
    }

    private var overflowMenu: some View {
        Menu {
            if let pauseResume = pauseResumeMenuItem {
                Button {
                    actions.togglePause()
                } label: {
                    Label(pauseResume.label, systemImage: pauseResume.systemImage)
                }
            }

            Button {
                draftObjective = goal.objective
                showEditSheet = true
            } label: {
                Label("Edit Objective", systemImage: "pencil")
            }

            Button {
                draftBudget = goal.tokenBudget.map { String($0) } ?? ""
                showBudgetSheet = true
            } label: {
                Label("Set Token Budget", systemImage: "gauge.with.dots.needle.50percent")
            }

            if goal.status != .complete {
                Button {
                    actions.markComplete()
                } label: {
                    Label("Mark Complete", systemImage: "checkmark.circle")
                }
            }

            Divider()

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Clear Goal", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .litterFont(size: 15, weight: .semibold)
                .foregroundColor(LitterTheme.textSecondary)
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Goal actions")
    }

    private func budgetGauge(progress: Double) -> some View {
        let percent = Int((progress * 100).rounded())
        return HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LitterTheme.meta.opacity(0.18))
                    Capsule()
                        .fill(
                            progressTint
                        )
                        .frame(width: max(geo.size.width * animatedProgress, animatedProgress > 0 ? 6 : 0))
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())

            HStack(spacing: 4) {
                if let budgetLabel {
                    Text(budgetLabel)
                        .litterMeta()
                }
                Text("\(percent)%")
                    .litterMeta(progressTextTint)
            }
            .fixedSize()
        }
    }

    private var canTogglePause: Bool {
        switch goal.status {
        case .active, .paused, .blocked, .usageLimited, .budgetLimited: return true
        case .complete: return false
        }
    }

    private var pauseToggleAccessibilityLabel: String {
        switch goal.status {
        case .active: return "Pause goal"
        case .paused: return "Resume goal"
        case .blocked: return "Resume goal (override block)"
        case .usageLimited: return "Resume goal (override usage cap)"
        case .budgetLimited: return "Resume goal (override budget cap)"
        case .complete: return "Goal complete"
        }
    }

    private var pauseResumeMenuItem: (label: String, systemImage: String)? {
        switch goal.status {
        case .active: return ("Pause Goal", "pause.circle")
        case .paused: return ("Resume Goal", "play.circle")
        case .blocked: return ("Resume Goal (override block)", "play.circle")
        case .usageLimited: return ("Resume Goal (override usage cap)", "play.circle")
        case .budgetLimited: return ("Resume Goal (override cap)", "play.circle")
        case .complete: return nil
        }
    }

    private var statusTint: Color {
        switch goal.status {
        case .active, .paused, .complete: return LitterTheme.meta
        case .blocked, .usageLimited, .budgetLimited: return LitterTheme.warning
        }
    }

    private var statusLabel: String {
        switch goal.status {
        case .active: return "active"
        case .paused: return "paused"
        case .blocked: return "blocked"
        case .usageLimited: return "usage limit"
        case .budgetLimited: return "limited"
        case .complete: return "complete"
        }
    }

    private var budgetProgress: Double? {
        guard let budget = goal.tokenBudget, budget > 0 else { return nil }
        let raw = Double(goal.tokensUsed) / Double(budget)
        return min(max(raw, 0), 1)
    }

    private var budgetLabel: String? {
        guard let budget = goal.tokenBudget, budget > 0 else { return nil }
        return "\(formatTokens(goal.tokensUsed)) / \(formatTokens(budget))"
    }

    private var progressTextTint: Color {
        guard let progress = budgetProgress else { return LitterTheme.textSecondary }
        if progress >= 1.0 { return LitterTheme.danger }
        if progress >= 0.85 { return LitterTheme.warning }
        return LitterTheme.textSecondary
    }

    private var progressTint: Color {
        guard let progress = budgetProgress else { return LitterTheme.textSecondary }
        if progress >= 1.0 { return LitterTheme.danger }
        if progress >= 0.85 { return LitterTheme.warning }
        return LitterTheme.textSecondary
    }

    private func formatTokens(_ value: Int64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    private var hasUsageMetrics: Bool {
        goal.tokensUsed > 0 || goal.timeUsedSeconds > 0
    }

    private var usageMetricsRow: some View {
        HStack(spacing: 0) {
            if goal.tokensUsed > 0 {
                RollingMetricText(formatTokens(goal.tokensUsed))
            }
            if goal.tokensUsed > 0 && goal.timeUsedSeconds > 0 {
                Text(" · ")
            }
            if goal.timeUsedSeconds > 0 {
                RollingMetricText(formatSeconds(goal.timeUsedSeconds))
            }
            Spacer(minLength: 0)
        }
        .litterMeta()
    }

    private func formatSeconds(_ seconds: Int64) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let remainSecs = totalSeconds % 60
        if totalSeconds < 3600 {
            return remainSecs == 0 ? "\(minutes)m" : "\(minutes)m \(remainSecs)s"
        }
        let hours = totalSeconds / 3600
        let remainMins = (totalSeconds % 3600) / 60
        return remainMins == 0 ? "\(hours)h" : "\(hours)h \(remainMins)m"
    }
}

/// Card chrome for the goal row. On iOS 26+ uses Liquid Glass tinted with the
/// status color; on older iOS falls back to a vertical gradient that blends
/// the codeBackground into a subtle status-tinted wash at the bottom.
private struct GoalCardChromeModifier: ViewModifier {
    let statusTint: Color
    let cornerRadius: CGFloat

    /// Raised surface, no tint wash or stroke. Glass stays on iOS 26 so the
    /// card matches the composer it sits above.
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(LitterTheme.raised)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private struct ConversationComposerActiveTaskRowView: View {
    let summary: ConversationActiveTaskSummary

    var body: some View {
        HStack(spacing: LitterSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: LitterSpace.s) {
                    Text(summary.title)
                        .litterFont(size: 15, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)

                    Text(summary.progressLabel)
                        .litterMeta()
                }

                Text(summary.detail)
                    .litterMeta(LitterTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, LitterSpace.m)
        .padding(.vertical, LitterSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitterTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: LitterRadius.raised, style: .continuous))
    }
}
