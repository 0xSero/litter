import SwiftUI

struct ProjectChip: View {
    let project: AppProject?
    let disabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(label)
                    .litterMonoFont(size: 13)
                    .foregroundStyle(project != nil ? LitterTheme.textPrimary : LitterTheme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitterTheme.meta)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, LitterSpace.m)
            .frame(minHeight: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier(interactive: true))
        .accessibilityLabel("Project: \(label)")
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private var label: String {
        if let project {
            return projectDefaultLabel(cwd: project.cwd)
        }
        return disabled ? "no server" : "pick project"
    }
}
