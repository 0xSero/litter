import SwiftUI
import HairballUI
import UIKit

func isDiffLanguage(_ language: String?) -> Bool {
    guard let normalized = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return false
    }
    return normalized == "diff" || normalized == "patch"
}

struct SyntaxHighlightedDiffText: View {
    let diff: String
    var fontSize: CGFloat = 12

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.textScale) private var textScale
    @State private var renderedDiff = NSAttributedString(string: "")

    private struct RenderInputs: Equatable {
        let diff: String
        let fontSize: CGFloat
        let colorScheme: ColorScheme
        let themeSlug: String
    }

    var body: some View {
        DiffAttributedTextView(attributedText: renderedDiff)
        .task(id: renderInputs) {
            renderedDiff = syntaxHighlightedDiffAttributedString(
                diff: diff,
                fontSize: fontSize * textScale
            )
        }
    }

    private var renderInputs: RenderInputs {
        let resolved = colorScheme == .dark ? ThemeStore.shared.dark : ThemeStore.shared.light
        return RenderInputs(
            diff: diff,
            fontSize: fontSize * textScale,
            colorScheme: colorScheme,
            themeSlug: resolved.slug
        )
    }
}

private struct DiffAttributedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.showsHorizontalScrollIndicator = false
        textView.showsVerticalScrollIndicator = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.lineBreakMode = .byClipping
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if !uiView.attributedText.isEqual(to: attributedText) {
            uiView.attributedText = attributedText
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let targetSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let fitting = uiView.sizeThatFits(targetSize)
        return CGSize(width: ceil(fitting.width), height: ceil(fitting.height))
    }
}

private func syntaxHighlightedDiffAttributedString(
    diff: String,
    fontSize: CGFloat
) -> NSAttributedString {
    let monoFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let result = NSMutableAttributedString()

    for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
        let text = rawLine.last == "\r" ? String(rawLine.dropLast()) : String(rawLine)
        let kind = DiffSyntaxLineKind(text: text)
        result.append(
            attributedDiffLine(
                text: text,
                kind: kind,
                monoFont: monoFont
            )
        )
    }

    return result
}

private func attributedDiffLine(
    text: String,
    kind: DiffSyntaxLineKind,
    monoFont: UIFont
) -> NSAttributedString {
    let displayText = text.isEmpty ? " " : text
    let line = NSMutableAttributedString(
        string: displayText,
        attributes: [
            .font: monoFont,
            .foregroundColor: kind.foregroundColor,
            .backgroundColor: kind.backgroundColor,
        ]
    )
    line.append(
        NSAttributedString(
            string: "\n",
            attributes: [
                .font: monoFont,
                .foregroundColor: kind.foregroundColor,
                .backgroundColor: kind.backgroundColor,
            ]
        )
    )
    return line
}

private enum DiffSyntaxLineKind {
    case addition
    case deletion
    case hunk
    case metadata
    case context

    init(text: String) {
        if text.hasPrefix("@@") {
            self = .hunk
        } else if text.hasPrefix("+"), !text.hasPrefix("+++") {
            self = .addition
        } else if text.hasPrefix("-"), !text.hasPrefix("---") {
            self = .deletion
        } else if text.hasPrefix("diff --git ")
            || text.hasPrefix("index ")
            || text.hasPrefix("+++ ")
            || text.hasPrefix("--- ")
            || text.hasPrefix("new file mode ")
            || text.hasPrefix("deleted file mode ")
            || text.hasPrefix("rename from ")
            || text.hasPrefix("rename to ")
            || text.hasPrefix("similarity index ")
            || text.hasPrefix("Binary files ") {
            self = .metadata
        } else {
            self = .context
        }
    }

    var foregroundColor: UIColor {
        switch self {
        case .addition:
            return UIColor(LitterTheme.success)
        case .deletion:
            return UIColor(LitterTheme.danger)
        case .hunk:
            return UIColor(LitterTheme.accentStrong)
        case .metadata:
            return UIColor(LitterTheme.textSecondary)
        case .context:
            return UIColor(LitterTheme.textBody)
        }
    }

    var backgroundColor: UIColor {
        switch self {
        case .addition:
            return UIColor(LitterTheme.success).withAlphaComponent(0.12)
        case .deletion:
            return UIColor(LitterTheme.danger).withAlphaComponent(0.12)
        case .hunk:
            return UIColor(LitterTheme.accentStrong).withAlphaComponent(0.12)
        case .metadata:
            return UIColor(LitterTheme.surface).withAlphaComponent(0.72)
        case .context:
            return UIColor(LitterTheme.codeBackground).withAlphaComponent(0.72)
        }
    }
}
