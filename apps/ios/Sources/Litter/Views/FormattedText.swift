import SwiftUI
import UIKit

/// Drop-in replacement for `Text` that applies inline formatting such as
/// plugin-reference pills (`[@Name](plugin://plugin-name@marketplace)`).
///
/// Parsing lives in shared Rust (`parsePluginRefs`) so iOS/Android stay in
/// sync. Falls back to plain `Text` when the input contains nothing to
/// format. Style via modifiers on this view: `.font(...)`,
/// `.foregroundStyle(...)`. Pills always render with the accent color.
struct FormattedText: View {
    let text: String
    /// When > 0, renders single-line (horizontal) with truncation; when 0 or
    /// nil, wraps via a FlowLayout.
    var lineLimit: Int? = nil

    var body: some View {
        content
            .environment(\.openURL, externalBrowserAction)
    }

    @ViewBuilder
    private var content: some View {
        let segments = parsePluginRefs(input: text)
        if segments.count == 1, case .text(let t) = segments.first {
            Text(linkifiedText(t))
                .lineLimit(lineLimit)
        } else if lineLimit == 1 {
            singleLine(segments)
        } else {
            multiLine(segments)
        }
    }

    private func singleLine(_ segments: [TitleSegment]) -> some View {
        // spacing=0: segments already carry the original whitespace, so the
        // HStack must not add extra.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(linkifiedText(text))
                        .lineLimit(1)
                        .truncationMode(.tail)
                case .pluginRef(let displayName, let pluginName, _):
                    PluginPill(displayName: displayName, pluginName: pluginName)
                        .fixedSize()
                }
            }
        }
    }

    private func multiLine(_ segments: [TitleSegment]) -> some View {
        // spacing=0: word pieces produced by splitPreservingWhitespace include
        // their own whitespace runs, so FlowLayout shouldn't add extra.
        FlowLayout(spacing: 0, rowSpacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    let pieces = splitPreservingWhitespace(text)
                    ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                        Text(linkifiedText(piece))
                            .fixedSize()
                    }
                case .pluginRef(let displayName, let pluginName, _):
                    PluginPill(displayName: displayName, pluginName: pluginName)
                        .fixedSize()
                }
            }
        }
    }

    private func splitPreservingWhitespace(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var inWhitespace = false
        for ch in text {
            let isWs = ch.isWhitespace
            if current.isEmpty {
                current.append(ch)
                inWhitespace = isWs
            } else if isWs == inWhitespace {
                current.append(ch)
            } else {
                pieces.append(current)
                current = String(ch)
                inWhitespace = isWs
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private func linkifiedText(_ value: String) -> AttributedString {
        var attributed = AttributedString(value)
        guard let linkDetector = Self.linkDetector else { return attributed }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in linkDetector.matches(in: value, options: [], range: fullRange) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let stringRange = Range(match.range, in: value),
                  let lowerBound = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upperBound = AttributedString.Index(stringRange.upperBound, within: attributed) else {
                continue
            }
            attributed[lowerBound..<upperBound].link = url
        }
        return attributed
    }

    private var externalBrowserAction: OpenURLAction {
        OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return .systemAction
            }
            UIApplication.shared.open(url)
            return .handled
        }
    }

    private static let linkDetector: NSDataDetector? = {
        // The detector is immutable after construction and reused across
        // message rows so long transcripts don't repeatedly compile URL rules.
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
}

struct PluginPill: View {
    let displayName: String
    let pluginName: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(LitterTheme.accent)
            Text(displayName)
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

    private var iconName: String {
        switch pluginName {
        case "computer-use": return "display"
        default: return "puzzlepiece.extension.fill"
        }
    }
}

// MARK: - FlowLayout

/// Minimal left-to-right wrapping layout.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(CGFloat(0)) { acc, row in acc + row.height }
            + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for entry in row.entries {
                let sz = entry.size
                subviews[entry.index].place(
                    at: CGPoint(x: x, y: y + (row.height - sz.height) / 2),
                    proposal: ProposedViewSize(sz)
                )
                x += sz.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var entries: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let sz = sub.sizeThatFits(.unspecified)
            let addition = rows[rows.count - 1].entries.isEmpty ? sz.width : sz.width + spacing
            if rows[rows.count - 1].width + addition > maxWidth && !rows[rows.count - 1].entries.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].entries.isEmpty
            rows[rows.count - 1].entries.append((i, sz))
            rows[rows.count - 1].width += isFirst ? sz.width : sz.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, sz.height)
        }
        return rows
    }
}
