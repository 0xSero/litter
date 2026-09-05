import SwiftUI

@MainActor
@Observable
final class SkillMentionCatalog {
    private(set) var skillsByName: [String: SkillMetadata] = [:]

    @ObservationIgnored private var loader: (() async -> [SkillMetadata])?
    @ObservationIgnored private var loadStarted = false

    func configureLoader(_ loader: @escaping () async -> [SkillMetadata]) {
        self.loader = loader
    }

    func skill(named name: String) -> SkillMetadata? {
        skillsByName[name.lowercased()]
    }

    func loadIfNeeded() {
        guard !loadStarted, let loader else { return }
        loadStarted = true
        Task { @MainActor in
            let skills = await loader()
            skillsByName = Dictionary(
                skills.map { ($0.name.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
}

private struct SkillMentionCatalogKey: EnvironmentKey {
    static let defaultValue: SkillMentionCatalog? = nil
}

extension EnvironmentValues {
    var skillMentionCatalog: SkillMentionCatalog? {
        get { self[SkillMentionCatalogKey.self] }
        set { self[SkillMentionCatalogKey.self] = newValue }
    }
}

extension View {
    func skillMentionCatalog(_ catalog: SkillMentionCatalog) -> some View {
        environment(\.skillMentionCatalog, catalog)
    }
}

enum SkillMentionPiece: Equatable {
    case text(String)
    case mention(name: String, raw: String)
}

func splitSkillMentionPieces(_ text: String) -> [SkillMentionPiece] {
    let bytes = Array(text.utf8)
    guard bytes.contains(UInt8(ascii: "$")) else { return text.isEmpty ? [] : [.text(text)] }

    var pieces: [SkillMentionPiece] = []
    var runStart = 0
    var index = 0

    func flushRun(upTo end: Int) {
        guard end > runStart else { return }
        if let run = String(bytes: bytes[runStart..<end], encoding: .utf8), !run.isEmpty {
            pieces.append(.text(run))
        }
    }

    while index < bytes.count {
        guard bytes[index] == UInt8(ascii: "$") else {
            index += 1
            continue
        }
        if index > 0, isSkillMentionNameByte(bytes[index - 1]) {
            index += 1
            continue
        }
        let nameStart = index + 1
        guard nameStart < bytes.count, isSkillMentionNameByte(bytes[nameStart]) else {
            index += 1
            continue
        }
        var nameEnd = nameStart + 1
        while nameEnd < bytes.count, isSkillMentionNameByte(bytes[nameEnd]) {
            nameEnd += 1
        }
        guard let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8),
              let raw = String(bytes: bytes[index..<nameEnd], encoding: .utf8) else {
            index = nameEnd
            continue
        }
        flushRun(upTo: index)
        pieces.append(.mention(name: name, raw: raw))
        runStart = nameEnd
        index = nameEnd
    }

    flushRun(upTo: bytes.count)
    return pieces
}

func textContainsSkillMentionSyntax(_ text: String) -> Bool {
    splitSkillMentionPieces(text).contains { piece in
        if case .mention = piece { return true }
        return false
    }
}

private func isSkillMentionNameByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"),
        UInt8(ascii: "A")...UInt8(ascii: "Z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"),
        UInt8(ascii: "_"),
        UInt8(ascii: "-"):
        return true
    default:
        return false
    }
}

struct SkillPill: View {
    let skill: SkillMetadata
    @State private var showDetail = false

    var body: some View {
        Button {
            showDetail = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LitterTheme.accent)
                Text("$\(skill.name)")
                    .foregroundColor(LitterTheme.accent)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LitterTheme.accent.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skill \(skill.name)")
        .accessibilityHint("Shows the skill's description")
        .sheet(isPresented: $showDetail) {
            SkillMentionDetailView(skill: skill)
        }
    }
}

private struct SkillMentionDetailView: View {
    let skill: SkillMetadata
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(LitterTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName)
                                .litterFont(.title3, weight: .semibold)
                                .foregroundColor(LitterTheme.textPrimary)
                            Text("$\(skill.name)")
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        Spacer()
                        Text(scopeLabel)
                            .litterFont(.caption2, weight: .semibold)
                            .foregroundColor(LitterTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(LitterTheme.accent.opacity(0.15))
                            )
                    }

                    if !description.isEmpty {
                        Text(description)
                            .litterFont(.body)
                            .foregroundColor(LitterTheme.textPrimary)
                            .textSelection(.enabled)
                    }

                    if let prompt = skill.interface?.defaultPrompt,
                       !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Default prompt")
                                .litterFont(.caption, weight: .semibold)
                                .foregroundColor(LitterTheme.textSecondary)
                            Text(prompt)
                                .litterFont(.callout)
                                .foregroundColor(LitterTheme.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(LitterTheme.surface)
                                )
                        }
                    }

                    Text(skill.path.value)
                        .litterFont(.caption2)
                        .foregroundColor(LitterTheme.textSecondary)
                        .textSelection(.enabled)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var displayName: String {
        let interfaceName = skill.interface?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return interfaceName.isEmpty ? skill.name : interfaceName
    }

    private var description: String {
        let short = skill.shortDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return short.isEmpty ? skill.description : short
    }

    private var scopeLabel: String {
        switch skill.scope {
        case .user: return "User"
        case .repo: return "Repo"
        case .system: return "System"
        case .admin: return "Admin"
        }
    }
}
