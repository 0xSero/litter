import SwiftUI

struct CodeBlockView: View {
    let language: String
    let code: String
    var fontSize: CGFloat = LitterFont.conversationCodePointSize

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            if isDiffLanguage(language) {
                SyntaxHighlightedDiffText(
                    diff: code,
                    titleHint: language.isEmpty ? nil : language,
                    fontSize: LitterFont.conversationDiffPointSize
                )
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(code)
                    .litterMonoFont(size: fontSize)
                    .foregroundColor(LitterTheme.textBody)
                    .textSelection(.enabled)
                    // Let the text keep its natural width inside the horizontal
                    // scroller. A max-width frame here asks SwiftUI to squeeze
                    // long source lines, which produces ellipses instead of a
                    // scrollable code block.
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(LitterTheme.codeBackground.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .modifier(GlassRectModifier(cornerRadius: 8))
    }
}

#if DEBUG
#Preview("Code Block") {
    ZStack {
        LitterTheme.backgroundGradient.ignoresSafeArea()
        CodeBlockView(
            language: "swift",
            code: """
            struct SchedulerGate {
                let repoJobs = 100_000

                func canEnqueue(_ pending: Int) -> Bool {
                    pending < repoJobs
                }
            }
            """
        )
        .padding(20)
    }
}
#endif
