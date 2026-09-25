import SwiftUI

struct ProjectPickerSheet: View {
    let projects: [AppProject]
    let serverNamesById: [String: String]
    /// Precomputed set of local server IDs so rows don't each read
    /// `appModel.snapshot` (which would create N observation edges and
    /// re-render every row per streaming token).
    let localServerIds: Set<String>
    let onSelect: (AppProject) -> Void
    let onCreateNew: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [AppProject] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return projects }
        return projects.filter { project in
            let label = projectDefaultLabel(cwd: project.cwd).lowercased()
            let server = (serverNamesById[project.serverId] ?? "").lowercased()
            return label.contains(trimmed)
                || project.cwd.lowercased().contains(trimmed)
                || server.contains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                search
                Divider().opacity(0.3)
                list
            }
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(LitterTheme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onCreateNew()
                    } label: {
                        Label("New Project", systemImage: "plus")
                            .foregroundStyle(LitterTheme.textPrimary)
                    }
                }
            }
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LitterTheme.textMuted)
            TextField("Search projects", text: $query)
                .litterFont(.body)
                .foregroundStyle(LitterTheme.textPrimary)
                .tint(LitterTheme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LitterTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, LitterSpace.margin)
        .padding(.vertical, LitterSpace.m)
    }

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.id) { project in
                        row(for: project)
                    }
                }
            }
        }
    }

    private func row(for project: AppProject) -> some View {
        Button {
            onSelect(project)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(projectDefaultLabel(cwd: project.cwd))
                        .litterFont(.body)
                        .foregroundStyle(LitterTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        if let serverName = serverNamesById[project.serverId] {
                            Text("\(serverName) · ")
                        }
                        Text(PathDisplay.display(project.cwd, isLocal: localServerIds.contains(project.serverId)))
                            .truncationMode(.middle)
                    }
                    .litterMeta()
                    .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, LitterSpace.margin)
            .padding(.vertical, LitterSpace.m)
            .frame(minHeight: 62, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(LitterTheme.textMuted)
            Text("No projects yet")
                .litterFont(.body, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)
            Text("Tap + to pick a directory and start your first thread.")
                .litterFont(.footnote)
                .foregroundStyle(LitterTheme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                onCreateNew()
            } label: {
                Text("New Project")
                    .litterFont(.footnote, weight: .semibold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(minHeight: LitterSpace.hitTarget)
                    .background(Capsule().fill(LitterTheme.textPrimary))
                    .foregroundStyle(LitterTheme.surface)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
}
