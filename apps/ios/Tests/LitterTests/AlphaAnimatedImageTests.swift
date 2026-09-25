import ImageIO
import XCTest
@testable import Litter

final class AlphaAnimatedImageTests: XCTestCase {
    func testBitmapCopyPreservesPremultipliedColorAndTransparency() throws {
        let pixels = Data([128, 32, 0, 128, 0, 0, 0, 0])
        let image = try XCTUnwrap(CGImage(
            width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ))
        let bitmap = try XCTUnwrap(AlphaAnimatedImageView.bitmapFrame(from: image))
        XCTAssertEqual(try Self.renderedPixels(bitmap), pixels)
    }

    func testBundledAnimationsHaveMaterializedFramesWithoutChangingPlayback() async throws {
        for (name, count, height) in [("home_cat_entrance", 165, 203), ("home_cat", 120, 202)] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "webp"))
            let startedAt = ProcessInfo.processInfo.systemUptime
            let animation = await Task.detached(priority: .userInitiated) {
                AlphaAnimatedImageView.animation(from: url)
            }.value
            print("\(name) bitmap preparation: \(ProcessInfo.processInfo.systemUptime - startedAt) s")
            XCTAssertEqual(animation.frames.count, count)
            XCTAssertEqual(animation.frameEndTimes.count, count)
            XCTAssertEqual(animation.duration, Double(count) / 15, accuracy: 0.000_001)
            var retainedBytes = 0
            for (index, frame) in animation.frames.enumerated() {
                XCTAssertEqual(frame.width, 360)
                XCTAssertEqual(frame.height, height)
                XCTAssertEqual(frame.bitsPerComponent, 8)
                XCTAssertEqual(frame.bitsPerPixel, 32)
                XCTAssertEqual(frame.alphaInfo, .premultipliedLast)
                let bytes = try XCTUnwrap(frame.dataProvider?.data)
                XCTAssertEqual(CFDataGetLength(bytes), frame.bytesPerRow * frame.height)
                retainedBytes += CFDataGetLength(bytes)
                XCTAssertEqual(animation.frameEndTimes[index], Double(index + 1) / 15, accuracy: 0.000_001)
            }
            XCTAssertLessThan(retainedBytes, 48 * 1024 * 1024)

            // Compare first, middle and final composited frames with ImageIO's
            // original rendering, including all alpha pixels and color channels.
            // Both render into sRGB so provider layout/padding is irrelevant.
            let expectedFrames = try await Task.detached(priority: .userInitiated) {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                return try [0, count / 2, count - 1].map { index in
                    let original = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
                    return try Self.renderedPixels(original)
                }
            }.value
            for (index, expected) in zip([0, count / 2, count - 1], expectedFrames) {
                XCTAssertEqual(try Self.renderedPixels(animation.frames[index]), expected, "\(name) frame \(index)")
            }
        }
    }

    private static func renderedPixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }
}
