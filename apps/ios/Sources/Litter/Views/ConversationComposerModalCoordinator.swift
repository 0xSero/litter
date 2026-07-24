import SwiftUI
import PhotosUI
import UIKit

struct ConversationComposerModalCoordinator<Content: View>: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState

    let snapshot: ConversationComposerSnapshot
    let experimentalFeatures: [ExperimentalFeature]
    let experimentalFeaturesLoading: Bool
    let skills: [SkillMetadata]
    let skillsLoading: Bool
    @Binding var showAttachMenu: Bool
    @Binding var showPhotoPicker: Bool
    @Binding var showCamera: Bool
    @Binding var showFileImporter: Bool
    @Binding var selectedPhoto: PhotosPickerItem?
    @Binding var attachedImage: UIImage?
    @Binding var showModelSelector: Bool
    @Binding var showPermissionsSheet: Bool
    @Binding var showExperimentalSheet: Bool
    @Binding var showSkillsSheet: Bool
    @Binding var showRenamePrompt: Bool
    @Binding var renameCurrentThreadTitle: String
    @Binding var renameDraft: String
    @Binding var slashErrorMessage: String?
    @Binding var showMicPermissionAlert: Bool
    let onOpenSettings: () -> Void
    let onLoadSelectedPhoto: (PhotosPickerItem) async -> Void
    let onLoadSelectedFile: (URL) -> Void
    let onLoadExperimentalFeatures: () async -> Void
    let onIsExperimentalFeatureEnabled: (String, Bool) -> Bool
    let onSetExperimentalFeature: (String, Bool) async -> Void
    let onLoadSkills: (Bool, Bool) async -> Void
    let onRenameThread: (String) async -> Void
    @ViewBuilder let content: Content
    @State private var modelSelectorDetent: PresentationDetent = .large

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty {
                    return pending
                }
                return snapshot.threadModel.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: { appState.selectedModel = $0 }
        )
    }

    private var selectedAgentRuntimeKindBinding: Binding<AgentRuntimeKind?> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty {
                    return appState.selectedAgentRuntimeKind
                }
                return currentThread?.agentRuntimeKind
            },
            set: { appState.selectedAgentRuntimeKind = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty {
                    return pending
                }
                return snapshot.threadReasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.reasoningEffort = $0 }
        )
    }

    private var selectedApprovalValue: String {
        appState.approvalPolicy(for: snapshot.threadKey)
    }

    private var selectedSandboxValue: String {
        appState.sandboxMode(for: snapshot.threadKey)
    }

    private var selectedApprovalLabel: String {
        ComposerApprovalOption.allCases.first { $0.wireValue == selectedApprovalValue }?.title ?? "Custom"
    }

    private var selectedApprovalDescription: String {
        ComposerApprovalOption.allCases.first { $0.wireValue == selectedApprovalValue }?.description ?? "This approval policy is managed by the server."
    }

    private var selectedSandboxLabel: String {
        ComposerSandboxOption.allCases.first { $0.wireValue == selectedSandboxValue }?.title ?? "Custom"
    }

    private var selectedSandboxDescription: String {
        ComposerSandboxOption.allCases.first { $0.wireValue == selectedSandboxValue }?.description ?? "This sandbox setting is managed by the server."
    }

    private var currentThread: AppThreadSnapshot? {
        appModel.snapshot?.threads.first(where: { $0.key == snapshot.threadKey })
    }

    private var currentRuntimeSupportsPermissionOverrides: Bool {
        currentThread?.agentRuntimeKind.supportsThreadPermissionOverrides ?? true
    }

    private var hasAuthoritativeThreadPermissions: Bool {
        guard let thread = currentThread,
              thread.agentRuntimeKind.reportsEffectiveThreadPermissions else { return false }
        return threadPermissionsAreAuthoritative(
            approvalPolicy: thread.effectiveApprovalPolicy,
            sandboxPolicy: thread.effectiveSandboxPolicy
        )
    }

    private var currentApprovalLabel: String {
        guard hasAuthoritativeThreadPermissions else { return "Syncing..." }
        return currentThread?.effectiveApprovalPolicy?.displayTitle ?? "Syncing..."
    }

    private var currentSandboxLabel: String {
        guard hasAuthoritativeThreadPermissions else { return "Syncing..." }
        return currentThread?.effectiveSandboxPolicy?.displayTitle ?? "Syncing..."
    }

    private var usesThreadDefaults: Bool {
        selectedApprovalValue == ComposerApprovalOption.default.wireValue
            && selectedSandboxValue == ComposerSandboxOption.default.wireValue
    }

    private var attachSheetDetentHeight: CGFloat {
        let showsCamera = !LitterPlatform.isCatalyst
        let count = 2 + (showsCamera ? 1 : 0)
        return count >= 3 ? 260 : 210
    }

    var body: some View {
        content
            .sheet(isPresented: $showAttachMenu) {
                ConversationComposerAttachSheet(
                    onPickPhotoLibrary: {
                        showAttachMenu = false
                        showPhotoPicker = true
                    },
                    onChooseFile: {
                        showAttachMenu = false
                        showFileImporter = true
                    },
                    onTakePhoto: LitterPlatform.isCatalyst ? nil : {
                        showAttachMenu = false
                        showCamera = true
                    }
                )
                .presentationDetents([.height(attachSheetDetentHeight)])
                .presentationDragIndicator(.visible)
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: ConversationAttachmentSupport.supportedFileContentTypes,
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result,
                      let url = urls.first else { return }
                onLoadSelectedFile(url)
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await onLoadSelectedPhoto(item) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView(image: $attachedImage)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showModelSelector) {
                ModelSelectorSheet(
                    models: snapshot.availableModels,
                    catalogLoaded: appModel.snapshot?.serverSnapshot(for: snapshot.threadKey.serverId)?.availableModels != nil,
                    catalogError: appModel.modelCatalogError(for: snapshot.threadKey.serverId),
                    onRetryModels: {
                        Task {
                            await appModel.loadAvailableModelsIfNeeded(
                                serverId: snapshot.threadKey.serverId,
                                force: true
                            )
                        }
                    },
                    selectedModel: selectedModelBinding,
                    selectedAgentRuntimeKind: selectedAgentRuntimeKindBinding,
                    reasoningEffort: reasoningEffortBinding,
                    isReasoningEffortLocked: currentThread?.ampReasoningEffortLocked == true
                )
                .presentationDetents([.medium, .large], selection: $modelSelectorDetent)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .presentationBackground(LitterTheme.surface)
            }
            .onChange(of: showModelSelector) { _, isPresented in
                if isPresented {
                    modelSelectorDetent = .large
                }
            }
            .sheet(isPresented: $showPermissionsSheet) {
                permissionsSheetContent
                    .task(id: snapshot.threadKey.threadId) {
                        _ = await appModel.hydrateThreadPermissions(for: snapshot.threadKey, appState: appState)
                    }
            }
            .sheet(isPresented: $showExperimentalSheet) {
                experimentalSheetContent
            }
            .sheet(isPresented: $showSkillsSheet) {
                skillsSheetContent
            }
            .alert("Rename Thread", isPresented: Binding(
                get: { showRenamePrompt },
                set: { isPresented in
                    showRenamePrompt = isPresented
                    if !isPresented {
                        renameCurrentThreadTitle = ""
                        renameDraft = ""
                    }
                }
            )) {
                TextField("New thread title", text: $renameDraft)
                Button("Cancel", role: .cancel) {
                    showRenamePrompt = false
                }
                Button("Rename") {
                    let nextName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !nextName.isEmpty else { return }
                    Task { await onRenameThread(nextName) }
                }
            } message: {
                Text("Current thread title:\n\(renameCurrentThreadTitle)")
            }
            .alert("Slash Command Error", isPresented: Binding(
                get: { slashErrorMessage != nil },
                set: { if !$0 { slashErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { slashErrorMessage = nil }
            } message: {
                Text(slashErrorMessage ?? "Unknown error")
            }
            .alert("Microphone Access", isPresented: $showMicPermissionAlert) {
                Button("Open Settings", action: onOpenSettings)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Microphone permission is required for voice input. Enable it in Settings.")
            }
    }

    @ViewBuilder
    private var permissionsSheetContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Thread permissions")
                                    .foregroundStyle(LitterTheme.textPrimary)
                                    .litterFont(.headline)
                                Text(currentRuntimeSupportsPermissionOverrides ? "Changes apply on your next turn and later turns." : "This runtime controls its own permissions.")
                                    .foregroundStyle(LitterTheme.textMuted)
                                    .litterFont(.caption)
                            }
                            Spacer(minLength: 12)
                            Text(currentRuntimeSupportsPermissionOverrides ? (usesThreadDefaults ? "Using defaults" : "Custom override") : "Runtime managed")
                                .foregroundStyle(usesThreadDefaults ? LitterTheme.textSecondary : LitterTheme.accentStrong)
                                .litterFont(size: 11, weight: .semibold)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill((usesThreadDefaults ? LitterTheme.surfaceLight : LitterTheme.accentStrong).opacity(0.16))
                                )
                        }

                        HStack(spacing: 10) {
                            permissionSummaryTile(
                                title: "Next turn",
                                approval: selectedApprovalLabel,
                                sandbox: selectedSandboxLabel,
                                accent: LitterTheme.accentStrong
                            )
                            permissionSummaryTile(
                                title: "Current thread",
                                approval: currentApprovalLabel,
                                sandbox: currentSandboxLabel,
                                accent: hasAuthoritativeThreadPermissions ? LitterTheme.textSecondary : LitterTheme.warning
                            )
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(LitterTheme.surface.opacity(0.82))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(LitterTheme.border.opacity(0.55), lineWidth: 1)
                    )

                    if currentRuntimeSupportsPermissionOverrides {
                        permissionSection(
                            title: "Approval policy",
                            subtitle: "Choose when Codex asks for approval"
                        ) {
                            permissionDropdown(
                                title: selectedApprovalLabel,
                                detail: selectedApprovalDescription
                            ) {
                                ForEach(ComposerApprovalOption.allCases) { option in
                                    permissionMenuItem(
                                        title: option.title,
                                        description: option.description,
                                        isSelected: selectedApprovalValue == option.wireValue
                                    ) {
                                        appState.setPermissions(
                                            approvalPolicy: option.wireValue,
                                            sandboxMode: selectedSandboxValue,
                                            for: snapshot.threadKey
                                        )
                                    }
                                }
                            }
                        }

                        permissionSection(
                            title: "Sandbox settings",
                            subtitle: "Choose how much Codex can do when running commands"
                        ) {
                            permissionDropdown(
                                title: selectedSandboxLabel,
                                detail: selectedSandboxDescription
                            ) {
                                ForEach(ComposerSandboxOption.allCases) { option in
                                    permissionMenuItem(
                                        title: option.title,
                                        description: option.description,
                                        isSelected: selectedSandboxValue == option.wireValue
                                    ) {
                                        appState.setPermissions(
                                            approvalPolicy: selectedApprovalValue,
                                            sandboxMode: option.wireValue,
                                            for: snapshot.threadKey
                                        )
                                    }
                                }
                            }
                        }
                    } else {
                        unsupportedPermissionRuntimeCard
                    }
                }
                .padding(16)
                .padding(.bottom, 28)
            }
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showPermissionsSheet = false }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
    }

    private var unsupportedPermissionRuntimeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(LitterTheme.accentStrong)
                Text("Runtime-managed permissions")
                    .foregroundStyle(LitterTheme.textPrimary)
                    .litterFont(.subheadline, weight: .semibold)
            }
            Text("This agent does not support Litter-side thread permission overrides, so approval and sandbox choices are not sent for this session.")
                .foregroundStyle(LitterTheme.textMuted)
                .litterFont(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LitterTheme.surface.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LitterTheme.border.opacity(0.55), lineWidth: 1)
        )
    }

    private func permissionSummaryTile(
        title: String,
        approval: String,
        sandbox: String,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .foregroundStyle(LitterTheme.textSecondary)
                .litterFont(size: 11, weight: .semibold)
            VStack(alignment: .leading, spacing: 8) {
                permissionSummaryRow(label: "Approval", value: approval, accent: accent)
                permissionSummaryRow(label: "Sandbox", value: sandbox, accent: accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LitterTheme.surfaceLight.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LitterTheme.border.opacity(0.45), lineWidth: 1)
        )
    }

    private func permissionSummaryRow(label: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .foregroundStyle(LitterTheme.textMuted)
                .litterFont(size: 10, weight: .medium)
            Text(value)
                .foregroundStyle(accent)
                .litterFont(.subheadline, weight: .semibold)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionSection<SectionContent: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> SectionContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .litterFont(.headline)
                Text(subtitle)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .litterFont(.caption)
            }
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LitterTheme.surface.opacity(0.74))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(LitterTheme.border.opacity(0.5), lineWidth: 1)
        )
    }

    private func permissionDropdown<MenuContent: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> MenuContent
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(LitterTheme.textPrimary)
                        .litterFont(size: 14, weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(detail)
                        .foregroundStyle(LitterTheme.textMuted)
                        .litterFont(size: 11)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(LitterTheme.textMuted)
                    .imageScale(.small)
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LitterTheme.surfaceLight.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LitterTheme.border.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func permissionMenuItem(
        title: String,
        description: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .foregroundStyle(LitterTheme.textPrimary)
                        .litterFont(size: 14, weight: .semibold)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(LitterTheme.accentStrong)
                            .imageScale(.small)
                    }
                }
                Text(description)
                    .foregroundStyle(LitterTheme.textMuted)
                    .litterFont(size: 11)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    @ViewBuilder
    private var experimentalSheetContent: some View {
        NavigationStack {
            Group {
                if experimentalFeaturesLoading {
                    ProgressView().tint(LitterTheme.accent)
                } else if experimentalFeatures.isEmpty {
                    Text("No experimental features available")
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textMuted)
                } else {
                    List {
                        ForEach(Array(experimentalFeatures.enumerated()), id: \.element.id) { _, feature in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(feature.displayName ?? feature.name)
                                        .litterFont(.subheadline)
                                        .foregroundColor(LitterTheme.textPrimary)
                                    Text(feature.description ?? "")
                                        .litterFont(.caption)
                                        .foregroundColor(LitterTheme.textSecondary)
                                }
                                Spacer(minLength: 0)
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { onIsExperimentalFeatureEnabled(feature.id, feature.enabled) },
                                        set: { value in
                                            Task { await onSetExperimentalFeature(feature.name, value) }
                                        }
                                    )
                                )
                                .labelsHidden()
                                .tint(LitterTheme.accent)
                            }
                            .listRowBackground(LitterTheme.surface.opacity(0.6))
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Experimental")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reload") { Task { await onLoadExperimentalFeatures() } }
                        .foregroundColor(LitterTheme.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showExperimentalSheet = false }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var skillsSheetContent: some View {
        NavigationStack {
            Group {
                if skillsLoading {
                    ProgressView().tint(LitterTheme.accent)
                } else if skills.isEmpty {
                    Text("No skills available for this workspace")
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textMuted)
                } else {
                    List {
                        ForEach(skills) { skill in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(skill.name)
                                        .litterFont(.subheadline)
                                        .foregroundColor(LitterTheme.textPrimary)
                                    Spacer()
                                    if skill.enabled {
                                        Text("enabled")
                                            .litterFont(.caption2)
                                            .foregroundColor(LitterTheme.accent)
                                    }
                                }
                                Text(skill.description)
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textSecondary)
                                Text(skill.path.value)
                                    .litterFont(.caption2)
                                    .foregroundColor(LitterTheme.textMuted)
                            }
                            .listRowBackground(LitterTheme.surface.opacity(0.6))
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reload") { Task { await onLoadSkills(true, true) } }
                        .foregroundColor(LitterTheme.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSkillsSheet = false }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
    }
}
