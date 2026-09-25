import CryptoKit
import ImageIO
import UIKit
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

    @MainActor
    func testCompletedFinalFramePersistsForOnlyTheNextReplacement() throws {
        let (first, last) = try Self.coloredFrames()
        let view = UIImageView()
        let coordinator = AlphaAnimatedImageView.Coordinator()
        var callbackCount = 0
        var callbackSawLastFrame = false
        coordinator.configure(view, fileURL: Self.uncachedURL(), repeatCount: 1) {
            callbackCount += 1
            callbackSawLastFrame = view.image?.cgImage === last
        }
        coordinator.apply(Self.animation(first, last), to: view, repeatCount: 1)
        let completed = try XCTUnwrap(view.layer.animation(forKey: "alphaFrames"))
        coordinator.animationDidStop(completed, finished: true)
        coordinator.animationDidStop(completed, finished: true)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertTrue(callbackSawLastFrame, "Install the final model image before the callback changes the URL")

        coordinator.configure(view, fileURL: Self.uncachedURL(), repeatCount: 0, onFinished: nil)
        XCTAssertEqual(try Self.renderedPixels(XCTUnwrap(view.image?.cgImage)), try Self.renderedPixels(last))
        XCTAssertNil(view.layer.animation(forKey: "alphaFrames"))
        // A second change interrupts the pending replacement; do not preserve
        // an old session's image through arbitrary subsequent configurations.
        coordinator.configure(view, fileURL: Self.uncachedURL(), repeatCount: 0, onFinished: nil)
        XCTAssertNil(view.image)
        coordinator.stop()
    }

    @MainActor
    func testInterruptedAnimationClearsOnReplacement() throws {
        let (first, last) = try Self.coloredFrames()
        let view = UIImageView()
        let coordinator = AlphaAnimatedImageView.Coordinator()
        var callbackCount = 0
        coordinator.configure(view, fileURL: Self.uncachedURL(), repeatCount: 1) { callbackCount += 1 }
        coordinator.apply(Self.animation(first, last), to: view, repeatCount: 1)
        let interrupted = try XCTUnwrap(view.layer.animation(forKey: "alphaFrames"))
        coordinator.animationDidStop(interrupted, finished: false)
        coordinator.configure(view, fileURL: Self.uncachedURL(), repeatCount: 0, onFinished: nil)
        XCTAssertNil(view.image)
        XCTAssertEqual(callbackCount, 0)
        coordinator.stop()
    }

    @MainActor
    func testOldAnimationCompletionCannotFinishReplacementOrRestoreAfterStop() throws {
        let (first, last) = try Self.coloredFrames()
        let view = UIImageView()
        let coordinator = AlphaAnimatedImageView.Coordinator()
        coordinator.configure(view, fileURL: Self.uncachedURL(), repeatCount: 1, onFinished: nil)
        coordinator.apply(Self.animation(first, last), to: view, repeatCount: 1)
        let oldAnimation = try XCTUnwrap(view.layer.animation(forKey: "alphaFrames"))
        var callbackCount = 0
        coordinator.configure(view, fileURL: Self.uncachedURL(), repeatCount: 1) { callbackCount += 1 }
        coordinator.apply(Self.animation(first, first), to: view, repeatCount: 1)
        let currentAnimation = try XCTUnwrap(view.layer.animation(forKey: "alphaFrames"))
        coordinator.animationDidStop(oldAnimation, finished: true)
        XCTAssertTrue(view.image?.cgImage === first)
        XCTAssertEqual(callbackCount, 0)
        AlphaAnimatedImageView.dismantleUIView(view, coordinator: coordinator)
        coordinator.animationDidStop(currentAnimation, finished: true)
        XCTAssertNil(view.image)
        XCTAssertEqual(callbackCount, 0)
    }

    @MainActor
    func testCompletedImageDoesNotCarryAcrossImageViews() throws {
        let (first, last) = try Self.coloredFrames()
        let view = UIImageView()
        let coordinator = AlphaAnimatedImageView.Coordinator()
        let url = Self.uncachedURL()
        coordinator.configure(view, fileURL: url, repeatCount: 1, onFinished: nil)
        coordinator.apply(Self.animation(first, last), to: view, repeatCount: 1)
        coordinator.animationDidStop(try XCTUnwrap(view.layer.animation(forKey: "alphaFrames")), finished: true)
        let replacementView = UIImageView(image: UIImage(cgImage: last))
        coordinator.configure(replacementView, fileURL: url, repeatCount: 1, onFinished: nil)
        XCTAssertNil(replacementView.image)
        XCTAssertNil(view.image)
        XCTAssertNil(view.layer.animation(forKey: "alphaFrames"))
        coordinator.stop()
    }

    @MainActor
    func testStopAndNewGenerationRejectPendingLoads() async throws {
        let (first, _) = try Self.coloredFrames()
        let url = Self.uncachedURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, first, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let stoppedView = UIImageView()
        let stopped = AlphaAnimatedImageView.Coordinator()
        stopped.configure(stoppedView, fileURL: url, repeatCount: 1) {
            XCTFail("A stopped load must not finish playback")
        }
        AlphaAnimatedImageView.dismantleUIView(stoppedView, coordinator: stopped)
        let replacedView = UIImageView()
        let replaced = AlphaAnimatedImageView.Coordinator()
        replaced.configure(replacedView, fileURL: url, repeatCount: 1) {
            XCTFail("A stale generation must not finish playback")
        }
        replaced.configure(replacedView, fileURL: Self.uncachedURL(), repeatCount: 1) {
            XCTFail("An empty replacement must not receive stale playback completion")
        }

        // A second real consumer coalesces onto the same one-frame decode.
        // Its completion drains the preceding callbacks without sleep/polling.
        let decoded = expectation(description: "shared pending decode drained")
        let observerView = UIImageView()
        let observer = AlphaAnimatedImageView.Coordinator()
        observer.configure(observerView, fileURL: url, repeatCount: 1) { decoded.fulfill() }
        await fulfillment(of: [decoded], timeout: 5)
        XCTAssertNil(stoppedView.image)
        XCTAssertNil(stoppedView.layer.animation(forKey: "alphaFrames"))
        XCTAssertNil(replacedView.image)
        stopped.stop()
        replaced.stop()
        observer.stop()
    }

    private static func uncachedURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    }

    private static func coloredFrames() throws -> (CGImage, CGImage) {
        func image(_ bytes: [UInt8]) throws -> CGImage {
            try XCTUnwrap(CGImage(
                width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
            ))
        }
        return try (image([255, 0, 0, 255]), image([0, 0, 255, 255]))
    }

    private static func animation(_ first: CGImage, _ last: CGImage) -> AlphaAnimatedImageView.Animation {
        .init(frames: [first, last], frameEndTimes: [0.5, 1], duration: 1)
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
