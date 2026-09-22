import XCTest
@testable import Litter

@MainActor
final class StreamingAssistantRenderCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StreamingAssistantRenderCache.shared.reset()
    }

    func testAppendOnlyStreamingReusesStablePrefixSegments() {
        let itemId = "assistant-1"
        let prefix = String(repeating: "alpha ", count: 300) + "\n\n"
        let tail = String(repeating: "beta ", count: 1000)
        let initialText = prefix + tail
        let appendedText = initialText + "gamma"

        let initialSegments = StreamingAssistantRenderCache.shared.segments(
            itemId: itemId,
            text: initialText
        )
        let appendedSegments = StreamingAssistantRenderCache.shared.segments(
            itemId: itemId,
            text: appendedText
        )

        XCTAssertGreaterThanOrEqual(initialSegments.count, 2)
        XCTAssertGreaterThanOrEqual(appendedSegments.count, 2)
        XCTAssertEqual(initialSegments.first?.id, appendedSegments.first?.id)
        XCTAssertNotEqual(initialSegments.last?.id, appendedSegments.last?.id)
    }

    func testNonAppendEditRebuildsStreamingSegments() {
        let itemId = "assistant-2"
        let prefix = String(repeating: "alpha ", count: 300) + "\n\n"
        let tail = String(repeating: "beta ", count: 1000)
        let initialText = prefix + tail
        let editedText = "omega " + String(initialText.dropFirst("alpha ".count))

        let initialSegments = StreamingAssistantRenderCache.shared.segments(
            itemId: itemId,
            text: initialText
        )
        let editedSegments = StreamingAssistantRenderCache.shared.segments(
            itemId: itemId,
            text: editedText
        )

        XCTAssertFalse(initialSegments.isEmpty)
        XCTAssertFalse(editedSegments.isEmpty)
        XCTAssertNotEqual(initialSegments.first?.id, editedSegments.first?.id)
    }

    func testMathDelimitersUseRenderableSegments() {
        let segments = StreamingAssistantRenderCache.shared.segments(
            itemId: "assistant-math",
            text: "Inline \\(a+b\\)\n\n\\[\nc+d\n\\]"
        )

        XCTAssertEqual(segments.count, 2)

        guard case .markdown(let inline, _) = segments[0].kind else {
            return XCTFail("Expected inline math markdown segment")
        }
        XCTAssertEqual(inline, "Inline $a+b$")

        guard case .codeBlock(let language, let code, _) = segments[1].kind else {
            return XCTFail("Expected display math code block segment")
        }
        XCTAssertEqual(language, "math")
        XCTAssertEqual(code, "c+d")
    }

    /// Rendered content of each segment. Segment identities are refresh keys,
    /// not content, and the incremental path hashes a growing chunk while a
    /// re-parse hashes the whole one, so only the content is comparable.
    private func renderedContent(
        _ segments: [MessageRenderCache.AssistantSegment]
    ) -> [String] {
        segments.map { segment in
            switch segment.kind {
            case .markdown(let content, _):
                return "markdown:\(content)"
            case .codeBlock(let language, let code, _):
                return "code:\(language ?? ""):\(code)"
            case .image(let data, _):
                return "image:\(data.count)"
            case .localImage(let path, _):
                return "localImage:\(path)"
            }
        }
    }

    /// Streaming a paragraph token by token must produce exactly the segments a
    /// cold parse of the same text produces. The incremental append path exists
    /// only to skip work, so any divergence here is a rendering bug.
    func testAppendOnlyStreamMatchesColdParse() {
        let itemId = "assistant-append"
        let token = "The quick brown fox jumps over the lazy dog. 123 "
        var text = "Start here. "
        var streamed: [MessageRenderCache.AssistantSegment] = []

        for _ in 0..<200 {
            text += token
            streamed = StreamingAssistantRenderCache.shared.segments(itemId: itemId, text: text)
        }

        StreamingAssistantRenderCache.shared.reset()
        let cold = StreamingAssistantRenderCache.shared.segments(itemId: itemId, text: text)

        XCTAssertEqual(renderedContent(cold), renderedContent(streamed))
    }

    /// Appends that can move a markdown block boundary — newlines, tables,
    /// fences, math delimiters — must still match a cold parse.
    func testStructuralAppendsMatchColdParse() {
        let itemId = "assistant-structural"
        let appends = [
            "\n\nSecond paragraph starts here.",
            "\n| a | b |\n| - | - |",
            "\n```swift\nlet x = 1",
            "\nClosing $inline$ math and \\[display\\]",
            "\n- list item one\n- list item two",
            "\n# Heading\n> quote",
            "\nSee https://example.com/docs for more.",
            "\nAnd one more plain sentence after the URL.",
            "\nCafé ☕️ and 日本語 text.",
            "\n```\ncode fence body",
        ]

        var text = "Opening paragraph."
        for append in appends {
            let previous = text
            text += append
            let incremental = StreamingAssistantRenderCache.shared.segments(
                itemId: itemId,
                text: text
            )

            StreamingAssistantRenderCache.shared.reset()
            let cold = StreamingAssistantRenderCache.shared.segments(
                itemId: itemId,
                text: text
            )
            XCTAssertEqual(
                renderedContent(cold),
                renderedContent(incremental),
                "segments diverged after appending \(append.debugDescription) to \(previous.debugDescription)"
            )

            // Re-seed the incremental entry so the next append builds on it.
            StreamingAssistantRenderCache.shared.reset()
            _ = StreamingAssistantRenderCache.shared.segments(itemId: itemId, text: previous)
            _ = StreamingAssistantRenderCache.shared.segments(itemId: itemId, text: text)
        }
    }
}
