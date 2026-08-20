import XCTest
@testable import Litter

final class MessageContentBridgeTests: XCTestCase {
    func testAssistantRenderBlocksSplitMarkdownCodeAndImages() {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
        let text = """
        # Heading

        Intro

        ![img](data:image/png;base64,\(pngBase64))

        ```swift
        print("hi")
        ```
        """

        let blocks = MessageContentBridge.assistantRenderBlocks(text)

        XCTAssertEqual(blocks.count, 4)

        guard case .markdown(let heading) = blocks[0] else {
            return XCTFail("Expected markdown heading block")
        }
        XCTAssertEqual(heading, "# Heading")

        guard case .markdown(let intro) = blocks[1] else {
            return XCTFail("Expected markdown paragraph block")
        }
        XCTAssertEqual(intro, "Intro")

        guard case .inlineImage(let imageData) = blocks[2] else {
            return XCTFail("Expected inline image block")
        }
        XCTAssertFalse(imageData.isEmpty)

        guard case .codeBlock(let language, let code) = blocks[3] else {
            return XCTFail("Expected code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "print(\"hi\")")
    }

    func testAssistantRenderBlocksMapDisplayMathToMathCodeBlock() {
        let blocks = MessageContentBridge.assistantRenderBlocks("Before\n\n$$x^2$$\n\nAfter")

        XCTAssertEqual(blocks.count, 3)

        guard case .markdown(let before) = blocks[0] else {
            return XCTFail("Expected leading markdown block")
        }
        XCTAssertEqual(before, "Before")

        guard case .codeBlock(let language, let code) = blocks[1] else {
            return XCTFail("Expected display math code block")
        }
        XCTAssertEqual(language, "math")
        XCTAssertEqual(code, "x^2")

        guard case .markdown(let after) = blocks[2] else {
            return XCTFail("Expected trailing markdown block")
        }
        XCTAssertEqual(after, "After")
    }

    func testAssistantRenderBlocksNormalizeBackslashMathDelimiters() {
        let blocks = MessageContentBridge.assistantRenderBlocks("Inline \\(a+b\\)\n\n\\[\nc+d\n\\]")

        XCTAssertEqual(blocks.count, 2)

        guard case .markdown(let inline) = blocks[0] else {
            return XCTFail("Expected inline math to stay in markdown")
        }
        XCTAssertEqual(inline, "Inline $a+b$")

        guard case .codeBlock(let language, let code) = blocks[1] else {
            return XCTFail("Expected display math code block")
        }
        XCTAssertEqual(language, "math")
        XCTAssertEqual(code, "c+d")
    }

    func testAssistantRenderBlocksPromoteLocalPNGAndSVGPaths() {
        let blocks = MessageContentBridge.assistantRenderBlocks(
            "Preview ![chart](/tmp/chart.png) and `docs/system map.svg`."
        )

        XCTAssertEqual(blocks.count, 5)
        guard case .localImage(path: let pngPath) = blocks[1] else {
            return XCTFail("Expected PNG path image block")
        }
        XCTAssertEqual(pngPath, "/tmp/chart.png")

        guard case .localImage(path: let svgPath) = blocks[3] else {
            return XCTFail("Expected SVG path image block")
        }
        XCTAssertEqual(svgPath, "docs/system map.svg")
    }

    func testAssistantRenderBlocksLinkifyBareWebURL() {
        let blocks = MessageContentBridge.assistantRenderBlocks("Open https://openai.com now.")
        guard case .markdown(let markdown) = blocks.first else {
            return XCTFail("Expected markdown block")
        }
        XCTAssertEqual(markdown, "Open <https://openai.com> now.")
    }

    func testContainsMathDetectsInlineAndDisplayMath() {
        XCTAssertTrue(MessageContentBridge.containsMath("Inline $a+b$"))
        XCTAssertTrue(MessageContentBridge.containsMath("Before\n\n\\[\na+b\n\\]\n\nAfter"))
    }

    func testContainsMathIgnoresFencedCode() {
        let text = """
        ```tex
        $x$
        ```
        """

        XCTAssertFalse(MessageContentBridge.containsMath(text))
    }
}
