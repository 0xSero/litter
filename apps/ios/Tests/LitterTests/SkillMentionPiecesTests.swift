import XCTest
@testable import Litter

final class SkillMentionPiecesTests: XCTestCase {
    func testPlainTextStaysSinglePiece() {
        XCTAssertEqual(
            splitSkillMentionPieces("hello world"),
            [.text("hello world")]
        )
    }

    func testEmptyTextProducesNoPieces() {
        XCTAssertEqual(splitSkillMentionPieces(""), [])
    }

    func testMentionAtStart() {
        XCTAssertEqual(
            splitSkillMentionPieces("$cad make me a holder"),
            [.mention(name: "cad", raw: "$cad"), .text(" make me a holder")]
        )
    }

    func testMentionMidSentenceKeepsSurroundingWhitespace() {
        XCTAssertEqual(
            splitSkillMentionPieces("use $deep-research now"),
            [.text("use "), .mention(name: "deep-research", raw: "$deep-research"), .text(" now")]
        )
    }

    func testMultipleMentions() {
        XCTAssertEqual(
            splitSkillMentionPieces("$cad then $mujoco"),
            [
                .mention(name: "cad", raw: "$cad"),
                .text(" then "),
                .mention(name: "mujoco", raw: "$mujoco"),
            ]
        )
    }

    func testDollarAmountIsNotAMention() {
        XCTAssertEqual(
            splitSkillMentionPieces("that gig was worth $10k minimum"),
            [
                .text("that gig was worth "),
                .mention(name: "10k", raw: "$10k"),
                .text(" minimum"),
            ]
        )
    }

    func testDollarPrecededByNameByteIsNotAMention() {
        XCTAssertEqual(
            splitSkillMentionPieces("cost$cad"),
            [.text("cost$cad")]
        )
    }

    func testBareDollarIsPlainText() {
        XCTAssertEqual(
            splitSkillMentionPieces("give me $ now"),
            [.text("give me $ now")]
        )
    }

    func testTrailingDollarIsPlainText() {
        XCTAssertEqual(
            splitSkillMentionPieces("send $"),
            [.text("send $")]
        )
    }

    func testUnderscoreAndDigitsInName() {
        XCTAssertEqual(
            splitSkillMentionPieces("$skill_v2!"),
            [.mention(name: "skill_v2", raw: "$skill_v2"), .text("!")]
        )
    }

    func testMultibyteTextAroundMention() {
        XCTAssertEqual(
            splitSkillMentionPieces("héllo $cad — done"),
            [.text("héllo "), .mention(name: "cad", raw: "$cad"), .text(" — done")]
        )
    }

    func testMentionSyntaxDetection() {
        XCTAssertTrue(textContainsSkillMentionSyntax("$cad build it"))
        XCTAssertFalse(textContainsSkillMentionSyntax("no mentions here"))
        XCTAssertFalse(textContainsSkillMentionSyntax("price is 5$"))
    }
}
