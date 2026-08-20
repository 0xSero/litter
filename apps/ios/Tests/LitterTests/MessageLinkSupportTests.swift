import XCTest
@testable import Litter

final class MessageLinkSupportTests: XCTestCase {
    func testExtractsHttpAndHttpsLinks() {
        let links = MessageLinks.links(in: "see https://a.com/x and http://b.com")
        XCTAssertEqual(links.map(\.absoluteString), ["https://a.com/x", "http://b.com"])
    }

    func testIgnoresNonWebSchemesAndPlainText() {
        XCTAssertTrue(MessageLinks.links(in: "mail me at someone@example.com or ftp://x.com/f").isEmpty)
        XCTAssertTrue(MessageLinks.links(in: "no links here, cost is $200").isEmpty)
    }

    func testDeduplicatesAndCaps() {
        let repeated = Array(repeating: "https://a.com", count: 3).joined(separator: " ")
        XCTAssertEqual(MessageLinks.links(in: repeated).count, 1)

        let many = (1...9).map { "https://site\($0).com" }.joined(separator: " ")
        XCTAssertEqual(MessageLinks.links(in: many).count, 5)
    }

    func testCopyTitleTrimsSchemeAndLongPaths() {
        XCTAssertEqual(
            MessageLinks.copyTitle(for: URL(string: "https://example.com/releases/latest")!),
            "Copy example.com/releases/latest"
        )
        XCTAssertEqual(
            MessageLinks.copyTitle(for: URL(string: "https://example.com")!),
            "Copy example.com"
        )
        let long = MessageLinks.copyTitle(for: URL(string: "https://example.com/" + String(repeating: "a", count: 60))!)
        XCTAssertTrue(long.hasSuffix("…"))
    }
}
