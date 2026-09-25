import CryptoKit
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
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "png"))
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

            // Android keeps the shipping WebP originals. Only LitterTests
            // bundles them; every composited pixel, including alpha, must match.
            let referenceURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "webp"))
            try await Task.detached(priority: .userInitiated) {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(referenceURL as CFURL, nil))
                let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                XCTAssertEqual(CGImageSourceGetCount(source), count)
                XCTAssertEqual(CGImageSourceGetCount(encoded), count)
                for (index, frame) in animation.frames.enumerated() {
                    try autoreleasepool {
                        let original = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
                        XCTAssertEqual(frame.width, original.width)
                        XCTAssertEqual(frame.height, original.height)
                        XCTAssertEqual(frame.colorSpace?.name as String?, original.colorSpace?.name as String?)
                        XCTAssertEqual(
                            SHA256.hash(data: try Self.renderedPixels(frame)),
                            SHA256.hash(data: try Self.renderedPixels(original)),
                            "\(name) frame \(index)"
                        )
                        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded, index, nil) as? [CFString: Any])
                        let png = try XCTUnwrap(properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
                        let delay = try XCTUnwrap(png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                        XCTAssertEqual(delay, 1.0 / 15.0, accuracy: 0.000_001)
                    }
                }
            }.value
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
