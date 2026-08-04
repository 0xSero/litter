import UIKit
import XCTest
@testable import Litter

final class ConversationAttachmentSupportTests: XCTestCase {
    func testBuildTurnInputsOmitsWhitespaceOnlyTextAndKeepsAttachmentInput() {
        let attachment = AppUserInput.image(url: "data:image/png;base64,abc")

        let inputs = ConversationAttachmentSupport.buildTurnInputs(
            text: "   \n",
            additionalInput: [attachment]
        )

        XCTAssertEqual(inputs.count, 1)
        guard case .image(let url)? = inputs.first else {
            return XCTFail("Expected image input")
        }
        XCTAssertEqual(url, "data:image/png;base64,abc")
    }

    func testPreparedAttachmentCreatesImageUserInput() throws {
        let attachment = try XCTUnwrap(
            PreparedImageAttachment(
                data: Data([0x01, 0x02, 0x03]),
                mimeType: "image/png"
            ) as PreparedImageAttachment?
        )

        guard case .image(let url) = attachment.userInput else {
            return XCTFail("Expected image user input")
        }

        XCTAssertEqual(url, "data:image/png;base64,AQID")
    }

    func testPrepareImageUsesPNGWhenImageHasTransparency() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 1, y: 1, width: 2, height: 2))
        }

        let attachment = ConversationAttachmentSupport.prepareImage(image)

        XCTAssertEqual(attachment?.mimeType, "image/png")
        XCTAssertNotNil(attachment?.data)
    }

    func testPrepareImageUsesJPEGWhenImageIsOpaque() {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }

        let attachment = ConversationAttachmentSupport.prepareImage(image)

        XCTAssertEqual(attachment?.mimeType, "image/jpeg")
        XCTAssertNotNil(attachment?.data)
    }

    func testUnreadableImagePathDoesNotFallBackToFileAttachment() {
        let url = URL(fileURLWithPath: "/tmp/litter-missing-image.jpeg")

        let picked = ConversationAttachmentSupport.loadPickedFile(at: url)

        XCTAssertNil(picked)
    }

    func testPhotosLibraryInternalPathDoesNotBecomeFileAttachment() {
        let url = URL(
            fileURLWithPath: "/Users/example/Pictures/Photos Library.photoslibrary/resources/derivatives/4/photo.txt"
        )

        let picked = ConversationAttachmentSupport.loadPickedFile(at: url)

        XCTAssertNil(picked)
    }

    func testPhotosLibraryInternalPathDetection() {
        XCTAssertTrue(
            ConversationAttachmentSupport.isPhotosLibraryInternalPath(
                "/Users/example/Pictures/Photos Library.photoslibrary/resources/derivatives/4/photo.jpeg"
            )
        )
        XCTAssertFalse(
            ConversationAttachmentSupport.isPhotosLibraryInternalPath(
                "/Users/example/Desktop/photo.jpeg"
            )
        )
    }

    func testUnreadableNonImagePathCanStillBeMentionedAsFileAttachment() {
        let url = URL(fileURLWithPath: "/tmp/litter-missing-file.txt")

        let picked = ConversationAttachmentSupport.loadPickedFile(at: url)

        guard case .file(let attachment)? = picked else {
            return XCTFail("Expected file attachment")
        }
        XCTAssertEqual(attachment.label, "litter-missing-file")
        XCTAssertEqual(attachment.path, "/tmp/litter-missing-file.txt")
    }
}
