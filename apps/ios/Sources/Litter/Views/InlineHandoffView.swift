import SwiftUI

struct InlineHandoffView: View {
    /// The resolved handoff thread, supplied by the parent. This view used to
    /// resolve it itself from `appModel.snapshot` and re-resolve on
    /// `.onChange(of: appModel.snapshotRevision)` — a per-instance ~8 fps
    /// re-render for a view that lives inside a live transcript. The parent
    /// (`RealtimeVoiceScreen`) now mirrors the snapshot outside of `body` and
    /// passes the result down, so this view re-renders only when its own
    /// thread data actually changes.
    let thread: AppThreadSnapshot?
    let maxHeight: CGFloat

    @State private var contentHeight: CGFloat = 0

    private var entries: [InlineHandoffEntry] {
        guard let thread else { return [] }
        return thread.hydratedConversationItems
            .map(\.conversationItem)
            .compactMap(InlineHandoffEntry.init(item:))
    }

    private var scrollSignature: String? {
        guard let last = entries.last else { return nil }
        return "\(last.id):\(last.text.count)"
    }

    var body: some View {
        Group {
            if thread != nil, !entries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 12) {
                            ForEach(entries) { entry in
                                InlineHandoffRow(entry: entry)
                                    .id(entry.id)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("handoff-bottom")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(key: InlineHandoffContentHeightKey.self, value: geometry.size.height)
                            }
                        )
                    }
                    .frame(height: min(contentHeight, maxHeight))
                    .onPreferenceChange(InlineHandoffContentHeightKey.self) { contentHeight = $0 }
                    .onChange(of: scrollSignature) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("handoff-bottom", anchor: .bottom)
                        }
                    }
                }
            } else if thread != nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Color.white.opacity(0.7))
                    Text("Running...")
                        .font(LitterFont.styled(.caption))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct InlineHandoffRow: View {
    let entry: InlineHandoffEntry

    private var font: Font {
        switch entry.style {
        case .assistant:
            return LitterFont.styled(.body, weight: .medium)
        case .user:
            return LitterFont.styled(.caption)
        case .status, .error:
            return LitterFont.styled(.caption)
        }
    }

    private var color: Color {
        switch entry.style {
        case .assistant:
            return .white.opacity(0.9)
        case .user:
            return .white.opacity(0.58)
        case .status:
            return .white.opacity(0.46)
        case .error:
            return Color(hex: "#FF6B6B")
        }
    }

    var body: some View {
        Text(entry.text)
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
    }
}

private struct InlineHandoffEntry: Identifiable {
    enum Style {
        case user
        case assistant
        case status
        case error
    }

    let id: String
    let text: String
    let style: Style

    init?(item: ConversationItem) {
        switch item.content {
        case .user(let data):
            let text = data.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            self.id = item.id
            self.text = text
            self.style = .user
        case .assistant(let data):
            let text = data.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            self.id = item.id
            self.text = text
            self.style = .assistant
        case .codeReview(let data):
            guard let first = data.findings.first else { return nil }
            self.id = item.id
            self.text = "Review: \(first.title)"
            self.style = .assistant
        case .reasoning(let data):
            let summary = (data.summary + data.content)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return nil }
            self.id = item.id
            self.text = "Thinking: \(summary)"
            self.style = .status
        case .todoList(let data):
            guard !data.steps.isEmpty else { return nil }
            self.id = item.id
            self.text = "Plan: \(data.completedCount)/\(data.steps.count) done"
            self.style = .status
        case .proposedPlan:
            self.id = item.id
            self.text = "Planning…"
            self.style = .status
        case .commandExecution(let data):
            self.id = item.id
            self.text = InlineHandoffEntry.statusText(
                label: data.command.isEmpty ? "Working" : data.command,
                status: data.status.displayLabel
            )
            self.style = .status
        case .fileChange(let data):
            self.id = item.id
            let count = data.changes.count
            self.text = InlineHandoffEntry.statusText(
                label: count > 0 ? "Changed \(count) file\(count == 1 ? "" : "s")" : "Applying changes",
                status: data.status.displayLabel
            )
            self.style = .status
        case .turnDiff:
            self.id = item.id
            self.text = "Comparing changes"
            self.style = .status
        case .mcpToolCall(let data):
            self.id = item.id
            self.text = InlineHandoffEntry.statusText(label: data.tool, status: data.status.displayLabel)
            self.style = .status
        case .dynamicToolCall(let data):
            self.id = item.id
            self.text = InlineHandoffEntry.statusText(label: data.tool, status: data.status.displayLabel)
            self.style = .status
        case .multiAgentAction(let data):
            self.id = item.id
            self.text = InlineHandoffEntry.statusText(label: data.tool, status: data.status.displayLabel)
            self.style = .status
        case .webSearch(let data):
            self.id = item.id
            self.text = data.query.isEmpty ? "Searching web" : "Searching: \(data.query)"
            self.style = .status
        case .imageView(let data):
            self.id = item.id
            self.text = "Viewed image: \(workspaceTitle(for: data.path))"
            self.style = .status
        case .imageGeneration(let data):
            self.id = item.id
            switch data.status {
            case .completed:
                self.text = "Generated image"
                self.style = .status
            case .failed:
                self.text = "Image generation failed"
                self.style = .error
            default:
                self.text = "Generating image"
                self.style = .status
            }
        case .widget:
            return nil
        case .userInputResponse:
            self.id = item.id
            self.text = "Waiting for user input"
            self.style = .status
        case .divider(let kind):
            guard let text = InlineHandoffEntry.dividerText(kind) else { return nil }
            self.id = item.id
            self.text = text
            self.style = .status
        case .error(let data):
            let title = data.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = data.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = [title, message].filter { !$0.isEmpty }.joined(separator: ": ")
            guard !text.isEmpty else { return nil }
            self.id = item.id
            self.text = text
            self.style = .error
        case .note(let data):
            let body = data.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = data.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = [title, body].filter { !$0.isEmpty }.joined(separator: ": ")
            guard !text.isEmpty else { return nil }
            self.id = item.id
            self.text = text
            self.style = .status
        }
    }

    private static func statusText(label: String, status: String) -> String {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty else { return cleanStatus.isEmpty ? "Working" : cleanStatus }
        guard !cleanStatus.isEmpty else { return cleanLabel }
        return "\(cleanLabel) (\(cleanStatus))"
    }

    private static func dividerText(_ kind: ConversationDividerKind) -> String? {
        switch kind {
        case .contextCompaction(let isComplete):
            return isComplete ? "Context compacted" : "Compacting context"
        case .modelRerouted(_, let toModel, _):
            return "Switched to \(toModel)"
        case .reviewEntered(let review):
            return "Entered \(review)"
        case .reviewExited(let review):
            return "Exited \(review)"
        case .workedFor(let duration):
            return duration
        case .generic(let title, let detail):
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if cleanTitle.isEmpty && cleanDetail.isEmpty { return nil }
            return cleanDetail.isEmpty ? cleanTitle : "\(cleanTitle): \(cleanDetail)"
        }
    }
}

private struct InlineHandoffContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
