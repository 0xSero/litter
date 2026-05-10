import SwiftUI
import UIKit

struct ConversationComposerContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let attachedImage: UIImage?
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
    let voiceManager: VoiceTranscriptionManager
    let allowsVoiceInput: Bool
    @Binding var showAttachMenu: Bool
    let onClearAttachment: () -> Void
    let onRespondToPendingUserInput: ([String: [String]]) -> Void
    let onDismissPendingUserInput: () -> Void
    let onImplementPlan: () -> Void
    let onDismissPlanImplementation: () -> Void
    let onSteerQueuedFollowUp: (AppQueuedFollowUpPreview) -> Void
    let onDeleteQueuedFollowUp: (AppQueuedFollowUpPreview) -> Void
    let onRemovePluginMention: (PluginMentionSelection) -> Void
    let onPasteImage: (UIImage) -> Void
    let onOpenModePicker: () -> Void
    let onSendText: () -> Void
    let onStopRecording: () -> Void
    let onStartRecording: () -> Void
    let onInterrupt: () -> Void
    @Binding var inputText: String
    @Binding var isComposerFocused: Bool
    @Binding var composerSelectionRange: NSRange

    init(
        attachedImage: UIImage?,
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
        voiceManager: VoiceTranscriptionManager,
        allowsVoiceInput: Bool = true,
        showAttachMenu: Binding<Bool>,
        onClearAttachment: @escaping () -> Void,
        onRespondToPendingUserInput: @escaping ([String: [String]]) -> Void,
        onDismissPendingUserInput: @escaping () -> Void = {},
        onImplementPlan: @escaping () -> Void = {},
        onDismissPlanImplementation: @escaping () -> Void = {},
        onSteerQueuedFollowUp: @escaping (AppQueuedFollowUpPreview) -> Void,
        onDeleteQueuedFollowUp: @escaping (AppQueuedFollowUpPreview) -> Void,
        onRemovePluginMention: @escaping (PluginMentionSelection) -> Void = { _ in },
        onPasteImage: @escaping (UIImage) -> Void,
        onOpenModePicker: @escaping () -> Void,
        onSendText: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        inputText: Binding<String>,
        isComposerFocused: Binding<Bool>,
        composerSelectionRange: Binding<NSRange> = .constant(NSRange(location: 0, length: 0))
    ) {
        self.attachedImage = attachedImage
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
        self.voiceManager = voiceManager
        self.allowsVoiceInput = allowsVoiceInput
        _showAttachMenu = showAttachMenu
        self.onClearAttachment = onClearAttachment
        self.onRespondToPendingUserInput = onRespondToPendingUserInput
        self.onDismissPendingUserInput = onDismissPendingUserInput
        self.onImplementPlan = onImplementPlan
        self.onDismissPlanImplementation = onDismissPlanImplementation
        self.onSteerQueuedFollowUp = onSteerQueuedFollowUp
        self.onDeleteQueuedFollowUp = onDeleteQueuedFollowUp
        self.onRemovePluginMention = onRemovePluginMention
        self.onPasteImage = onPasteImage
        self.onOpenModePicker = onOpenModePicker
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
            if let attachedImage {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: attachedImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button(action: onClearAttachment) {
                            Image(systemName: "xmark.circle.fill")
                                .litterFont(.body)
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .offset(x: 4, y: -4)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
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
                    hasAttachment: attachedImage != nil,
                    allowsVoiceInput: allowsVoiceInput,
                    onPasteImage: onPasteImage,
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

private struct ConversationComposerPluginChipStrip: View {
    let plugins: [PluginMentionSelection]
    let onRemove: (PluginMentionSelection) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(plugins, id: \.path) { plugin in
                    HStack(spacing: 4) {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .litterFont(size: 10, weight: .semibold)
                            .foregroundStyle(LitterTheme.accent)
                        Text(plugin.displayTitle)
                            .litterFont(.caption, weight: .semibold)
                            .foregroundStyle(LitterTheme.accent)
                            .lineLimit(1)
                        Button {
                            onRemove(plugin)
                        } label: {
                            Image(systemName: "xmark")
                                .litterFont(size: 9, weight: .bold)
                                .foregroundStyle(LitterTheme.accent)
                                .padding(3)
                                .background(Circle().fill(LitterTheme.accent.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove plugin \(plugin.displayTitle)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LitterTheme.accent.opacity(0.12))
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

    private var foreground: Color {
        mode == .plan ? Color.black : LitterTheme.textPrimary
    }

    private var background: Color {
        mode == .plan ? LitterTheme.accent : LitterTheme.surfaceLight
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(label)
                    .litterFont(.caption, weight: .semibold)
                Image(systemName: "chevron.up.chevron.down")
                    .litterFont(size: 10, weight: .semibold)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(background))
        }
        .buttonStyle(.plain)
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LitterTheme.codeBackground.opacity(0.92))
        )
    }

    private var headerContent: some View {
        Group {
            Image(systemName: "list.bullet.clipboard")
                .litterFont(size: 12, weight: .semibold)
                .foregroundStyle(LitterTheme.accent)
            Text(isExpanded ? "Plan Progress" : "Plan")
                .litterFont(.caption, weight: .semibold)
                .foregroundStyle(LitterTheme.textPrimary)
            Text("\(completedCount)/\(progress.plan.count)")
                .litterMonoFont(size: 11, weight: .semibold)
                .foregroundStyle(LitterTheme.textSecondary)

            if !isExpanded {
                Text(currentStepText)
                    .litterFont(.caption)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            } else {
                Spacer(minLength: 0)
            }

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .litterFont(size: 10, weight: .semibold)
                .foregroundStyle(LitterTheme.textMuted)
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let explanation = progress.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explanation.isEmpty {
            Text(explanation)
                .litterFont(.caption)
                .foregroundStyle(LitterTheme.textSecondary)
        }

        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(progress.plan.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: iconName(for: step.status))
                        .litterFont(size: 11, weight: .semibold)
                        .foregroundStyle(iconColor(for: step.status))
                        .padding(.top, 2)
                    Text("\(index + 1).")
                        .litterMonoFont(size: 11, weight: .semibold)
                        .foregroundStyle(LitterTheme.textMuted)
                        .padding(.top, 1)
                    Text(step.step)
                        .litterFont(.caption)
                        .foregroundStyle(LitterTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func iconName(for status: AppPlanStepStatus) -> String {
        switch status {
        case .completed:
            return "checkmark.circle.fill"
        case .inProgress:
            return "circle.fill"
        case .pending:
            return "circle"
        }
    }

    private func iconColor(for status: AppPlanStepStatus) -> Color {
        switch status {
        case .completed:
            return LitterTheme.success
        case .inProgress:
            return LitterTheme.warning
        case .pending:
            return LitterTheme.textMuted
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
    @State private var pulsing = false
    @State private var animatedProgress: Double = 0

    private let cornerRadius: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                statusPill

                Text(goal.objective)
                    .litterFont(.caption)
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
            if goal.status == .active { pulsing = true }
        }
        .onChange(of: budgetProgress ?? 0) { _, new in
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                animatedProgress = new
            }
        }
        .onChange(of: goal.status) { _, new in
            pulsing = (new == .active)
        }
    }

    private var statusPill: some View {
        Button(action: { if canTogglePause { actions.togglePause() } }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 6, height: 6)
                    .opacity(goal.status == .active ? (pulsing ? 0.35 : 1.0) : 1.0)
                    .animation(
                        goal.status == .active
                            ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                            : .default,
                        value: pulsing
                    )

                Text(statusLabel)
                    .litterMonoFont(size: 10, weight: .semibold)
                    .foregroundColor(statusTint)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusTint.opacity(0.14)))
            .overlay(Capsule().stroke(statusTint.opacity(0.35), lineWidth: 0.5))
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
                .litterFont(size: 12, weight: .bold)
                .foregroundColor(LitterTheme.textSecondary)
                .frame(width: 24, height: 22)
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
                        .fill(statusTint.opacity(0.10))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [progressTint.opacity(0.85), progressTint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geo.size.width * animatedProgress, animatedProgress > 0 ? 6 : 0))
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())

            HStack(spacing: 4) {
                if let budgetLabel {
                    Text(budgetLabel)
                        .litterMonoFont(size: 10, weight: .semibold)
                        .foregroundColor(LitterTheme.textSecondary)
                }
                Text("\(percent)%")
                    .litterMonoFont(size: 10, weight: .bold)
                    .foregroundColor(progressTextTint)
            }
            .fixedSize()
        }
    }

    private var canTogglePause: Bool {
        switch goal.status {
        case .active, .paused, .budgetLimited: return true
        case .complete: return false
        }
    }

    private var pauseToggleAccessibilityLabel: String {
        switch goal.status {
        case .active: return "Pause goal"
        case .paused: return "Resume goal"
        case .budgetLimited: return "Resume goal (override budget cap)"
        case .complete: return "Goal complete"
        }
    }

    private var pauseResumeMenuItem: (label: String, systemImage: String)? {
        switch goal.status {
        case .active: return ("Pause Goal", "pause.circle")
        case .paused: return ("Resume Goal", "play.circle")
        case .budgetLimited: return ("Resume Goal (override cap)", "play.circle")
        case .complete: return nil
        }
    }

    private var statusTint: Color {
        switch goal.status {
        case .active: return LitterTheme.accent
        case .paused: return LitterTheme.textMuted
        case .budgetLimited: return LitterTheme.warning
        case .complete: return LitterTheme.success
        }
    }

    private var statusLabel: String {
        switch goal.status {
        case .active: return "active"
        case .paused: return "paused"
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
        guard let progress = budgetProgress else { return statusTint }
        if progress >= 1.0 { return LitterTheme.danger }
        if progress >= 0.85 { return LitterTheme.warning }
        return statusTint
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
        HStack(spacing: 6) {
            if goal.tokensUsed > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "circle.hexagongrid")
                        .litterMonoFont(size: 9, weight: .semibold)
                    Text(formatTokens(goal.tokensUsed))
                        .litterMonoFont(size: 10, weight: .semibold)
                }
                .foregroundColor(LitterTheme.textSecondary)
            }
            if goal.tokensUsed > 0 && goal.timeUsedSeconds > 0 {
                Text("·")
                    .litterMonoFont(size: 10, weight: .semibold)
                    .foregroundColor(LitterTheme.textMuted.opacity(0.6))
            }
            if goal.timeUsedSeconds > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .litterMonoFont(size: 9, weight: .semibold)
                    Text(formatSeconds(goal.timeUsedSeconds))
                        .litterMonoFont(size: 10, weight: .semibold)
                }
                .foregroundColor(LitterTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
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

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(statusTint.opacity(0.14)).interactive(),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(statusTint.opacity(0.20), lineWidth: 0.5)
                )
        } else {
            content
                .background(
                    LinearGradient(
                        colors: [
                            LitterTheme.codeBackground.opacity(0.92),
                            statusTint.opacity(0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(statusTint.opacity(0.28), lineWidth: 1)
                )
        }
    }
}

private struct ConversationComposerActiveTaskRowView: View {
    let summary: ConversationActiveTaskSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .litterFont(size: 11, weight: .semibold)
                .foregroundColor(LitterTheme.warning)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.title)
                        .litterFont(.caption, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)

                    Text(summary.progressLabel)
                        .litterMonoFont(size: 10, weight: .semibold)
                        .foregroundColor(LitterTheme.warning)
                }

                Text(summary.detail)
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitterTheme.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
