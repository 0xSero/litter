import XCTest
@testable import Litter

final class ConversationDisplayPreferenceTests: XCTestCase {
    func testDisplayModeResolvesUnknownValuesToCollapsed() {
        XCTAssertEqual(ConversationDetailDisplayMode.resolve("expanded"), .expanded)
        XCTAssertEqual(ConversationDetailDisplayMode.resolve("hidden"), .hidden)
        XCTAssertEqual(ConversationDetailDisplayMode.resolve("not-a-mode"), .collapsed)
    }

    func testCollapsedModeOnlyExpandsFailuresByDefault() {
        XCTAssertTrue(ConversationDetailDisplayMode.expanded.defaultExpanded())
        XCTAssertFalse(ConversationDetailDisplayMode.collapsed.defaultExpanded())
        XCTAssertTrue(ConversationDetailDisplayMode.collapsed.defaultExpanded(isFailed: true))
        XCTAssertFalse(ConversationDetailDisplayMode.hidden.defaultExpanded(isFailed: true))
    }

    /// Regression guard for 7066c5ab, which removed
    /// `ConversationLiveDetailRetentionPolicy` and left running tool calls
    /// collapsed until `ItemCompleted` landed — every tool call looked like the
    /// turn had frozen. A running tool call must be expanded in the default
    /// `.collapsed` mode so its output streams in, matching what
    /// `commandDefaultExpanded` already does for command executions.
    func testCollapsedModeExpandsInProgressToolCalls() {
        XCTAssertTrue(ConversationDetailDisplayMode.collapsed.defaultExpanded(isInProgress: true))
        XCTAssertTrue(
            ConversationDetailDisplayMode.collapsed.defaultExpanded(
                isFailed: true,
                isInProgress: true
            )
        )
        // Completed and not failed stays collapsed — the point of 7066c5ab.
        XCTAssertFalse(
            ConversationDetailDisplayMode.collapsed.defaultExpanded(
                isFailed: false,
                isInProgress: false
            )
        )
        // `.hidden` still wins over an in-flight call.
        XCTAssertFalse(ConversationDetailDisplayMode.hidden.defaultExpanded(isInProgress: true))
        // `.expanded` is unconditional.
        XCTAssertTrue(ConversationDetailDisplayMode.expanded.defaultExpanded(isInProgress: false))
    }

    func testConversationItemsHonorHiddenDetailModes() {
        let reasoning = ConversationItem(
            id: "reasoning",
            content: .reasoning(ConversationReasoningData(summary: ["thinking"], content: []))
        )
        let command = ConversationItem(
            id: "command",
            content: .commandExecution(
                ConversationCommandExecutionData(
                    command: "echo hi",
                    cwd: "",
                    status: .completed,
                    output: "hi",
                    exitCode: 0,
                    durationMs: nil,
                    processId: nil,
                    actions: []
                )
            )
        )
        let assistant = ConversationItem(
            id: "assistant",
            content: .assistant(
                ConversationAssistantMessageData(
                    text: "Done",
                    agentNickname: nil,
                    agentRole: nil,
                    phase: nil
                )
            )
        )

        XCTAssertFalse(reasoning.isVisible(
            reasoningDisplayMode: .hidden,
            commandDisplayMode: .collapsed,
            toolDisplayMode: .collapsed
        ))
        XCTAssertFalse(command.isVisible(
            reasoningDisplayMode: .collapsed,
            commandDisplayMode: .hidden,
            toolDisplayMode: .collapsed
        ))
        XCTAssertTrue(assistant.isVisible(
            reasoningDisplayMode: .hidden,
            commandDisplayMode: .hidden,
            toolDisplayMode: .hidden
        ))
    }
}
