import XCTest
@testable import Litter

final class ConversationDisplayPreferenceTests: XCTestCase {
    func testComposerIgnoresStaleRenderWhileUIKitEditIsInFlight() {
        var reconciler = ComposerTextReconciler(initialText: "hello")
        reconciler.recordUIKitEdit("hello!")

        XCTAssertFalse(reconciler.shouldApply(
            presentedText: "hello",
            currentUIKitText: "hello!",
            isEditing: true
        ))
        XCTAssertFalse(reconciler.shouldApply(
            presentedText: "hello!",
            currentUIKitText: "hello!",
            isEditing: true
        ))
    }

    func testComposerAppliesIntentionalExternalEdit() {
        var reconciler = ComposerTextReconciler(initialText: "hello")

        XCTAssertTrue(reconciler.shouldApply(
            presentedText: "prefilled prompt",
            currentUIKitText: "hello",
            isEditing: true
        ))
    }

    func testComposerAppliesBindingWhenNotEditing() {
        var reconciler = ComposerTextReconciler(initialText: "hello")
        reconciler.recordUIKitEdit("hello!")

        XCTAssertTrue(reconciler.shouldApply(
            presentedText: "hello",
            currentUIKitText: "hello!",
            isEditing: false
        ))
    }

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

    func testCollapsedModeExpandsInProgressToolCalls() {
        XCTAssertTrue(ConversationDetailDisplayMode.collapsed.defaultExpanded(isInProgress: true))
        XCTAssertFalse(
            ConversationDetailDisplayMode.collapsed.defaultExpanded(
                isFailed: false,
                isInProgress: false
            )
        )
        XCTAssertFalse(ConversationDetailDisplayMode.hidden.defaultExpanded(isInProgress: true))
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
