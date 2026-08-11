import SwiftUI

/// Primary Apps surface: list of all `SavedApp`s on disk. Always-visible
/// from the Home Dashboard's Apps toolbar button.
struct AppsListView: View {
    @State private var store = SavedAppsStore.shared
    @State private var navigation = SavedAppsNavigation.shared
    @State private var renameTarget: SavedApp?
    @State private var renameText: String = ""
    @State private var deleteTarget: SavedApp?
    @State private var detailAppId: String?

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            Group {
                if store.apps.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
        .navigationTitle("Apps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            store.reload()
            if let pending = navigation.consumeRequest() {
                detailAppId = pending
            }
        }
        .onChange(of: navigation.pendingOpenAppId) { _, newValue in
            if let id = newValue {
                detailAppId = id
                _ = navigation.consumeRequest()
            }
        }
        .navigationDestination(item: $detailAppId) { appId in
            SavedAppDetailView(appId: appId)
        }
        .sheet(item: $renameTarget) { app in
            renameSheet(for: app)
                .presentationDetents([.medium])
        }
        .alert(
            "Delete \"\(deleteTarget?.title ?? "")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    try? store.delete(id: target.id)
                }
                deleteTarget = nil
            }
        } message: {
            Text("This removes the app, its saved HTML, and its persisted state.")
        }
    }

    private var list: some View {
        List {
            ForEach(sortedApps, id: \.id) { app in
                Button {
                    detailAppId = app.id
                } label: {
                    row(for: app)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = app
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        renameText = app.title
                        renameTarget = app
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(LitterTheme.accent)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private var sortedApps: [SavedApp] {
        store.apps.sorted(by: { $0.updatedAtMs > $1.updatedAtMs })
    }

    private func row(for app: SavedApp) -> some View {
        HStack(spacing: 12) {
            monogram(for: app)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.title)
                    .litterFont(.body, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                    .lineLimit(1)
                Text(relativeUpdated(app))
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func monogram(for app: SavedApp) -> some View {
        let tint = monogramTint(for: app.id)
        let initials = monogramInitials(from: app.title)
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.25))
            Text(initials)
                .litterFont(.subheadline, weight: .bold)
                .foregroundColor(tint)
        }
        .frame(width: 40, height: 40)
    }

    private func monogramTint(for id: String) -> Color {
        // Deterministic per-app tint pulled from a small palette of theme
        // accents so existing apps keep the same color across launches.
        let palette: [Color] = [
            LitterTheme.accent,
            LitterTheme.accentStrong,
            LitterTheme.success,
            LitterTheme.warning,
            LitterTheme.danger,
            LitterTheme.textSystem,
        ]
        var hasher = Hasher()
        hasher.combine(id)
        let idx = abs(hasher.finalize()) % palette.count
        return palette[idx]
    }

    private func monogramInitials(from title: String) -> String {
        let words = title.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private func relativeUpdated(_ app: SavedApp) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(app.updatedAtMs) / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .litterFont(.largeTitle)
                .foregroundColor(LitterTheme.textMuted)
            Text("No apps yet")
                .litterFont(.title3, weight: .semibold)
                .foregroundColor(LitterTheme.textPrimary)
            Text("When the AI generates an interactive widget with an app_id, it saves here automatically.")
                .litterFont(.footnote)
                .foregroundColor(LitterTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func renameSheet(for app: SavedApp) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename App")
                .litterFont(.title3, weight: .semibold)
                .foregroundColor(LitterTheme.textPrimary)

            TextField("Title", text: $renameText)
                .litterFont(size: 15)
                .padding(10)
                .background(LitterTheme.surfaceLight.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundColor(LitterTheme.textPrimary)

            HStack {
                Button("Cancel") { renameTarget = nil }
                    .foregroundColor(LitterTheme.textSecondary)
                Spacer()
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { renameTarget = nil; return }
                    _ = try? store.rename(id: app.id, title: trimmed)
                    renameTarget = nil
                }
                .foregroundColor(LitterTheme.accent)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
        }
        .padding(20)
        .background(LitterTheme.surface.ignoresSafeArea())
    }
}
