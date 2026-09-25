import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

struct EncodingError: Error { let message: String }
func needed<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw EncodingError(message: message) }; return value
}
func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
func frameRecord(_ frame: CGImage, index: Int) throws -> [String: Any] {
    let bytes = try needed(frame.dataProvider?.data, "no owned bytes") as Data
    return ["index": index, "width": frame.width, "height": frame.height,
        "bytes_per_row": frame.bytesPerRow, "owned_bytes": bytes.count,
        "bits_per_component": frame.bitsPerComponent, "bits_per_pixel": frame.bitsPerPixel,
        "alpha_info": frame.alphaInfo.rawValue, "bitmap_info": frame.bitmapInfo.rawValue,
        "color_space": frame.colorSpace?.name as String? ?? "unnamed",
        "sha256": sha(bytes), "frame_end_seconds": Double(index + 1) / 15.0]
}
@main struct EncodeAPNG {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw EncodingError(message: "usage: encode-apng input.webp output.png")
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw EncodingError(message: "refusing to overwrite candidate")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        // Owned frames use exactly the shipping bitmap copy. No original
        // ImageIO provider reaches the APNG encoder.
        let frames: [CGImage] = try autoreleasepool {
            let source = try needed(CGImageSourceCreateWithURL(input as CFURL, options), "source unavailable")
            return try (0..<CGImageSourceGetCount(source)).map { index in
                try autoreleasepool {
                    let image = try needed(CGImageSourceCreateImageAtIndex(source,index,options), "source frame missing")
                    return try needed(BitmapCopy.bitmapFrame(from: image), "source bitmap failed")
                }
            }
        }
        let decoded = ProcessInfo.processInfo.systemUptime
        let expected = try frames.enumerated().map { index, frame in
            try autoreleasepool { try frameRecord(frame,index:index) }
        }
        let encodeStart = ProcessInfo.processInfo.systemUptime
        try autoreleasepool {
            let destination = try needed(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, frames.count,nil), "destination unavailable")
            CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
            let properties = [kCGImagePropertyPNGDictionary: [
                kCGImagePropertyAPNGDelayTime: 1.0 / 15.0,
                kCGImagePropertyAPNGUnclampedDelayTime: 1.0 / 15.0
            ]] as CFDictionary
            for frame in frames {
                autoreleasepool { CGImageDestinationAddImage(destination,frame,properties) }
            }
            guard CGImageDestinationFinalize(destination) else {
                throw EncodingError(message: "APNG finalization failed")
            }
        }
        let encoded = ProcessInfo.processInfo.systemUptime
        let actual: [[String: Any]] = try autoreleasepool {
            let source = try needed(CGImageSourceCreateWithURL(output as CFURL,options), "roundtrip source unavailable")
            guard CGImageSourceGetCount(source) == frames.count else {
                throw EncodingError(message: "roundtrip frame count differs")
            }
            return try (0..<frames.count).map { index in
                try autoreleasepool {
                    let image = try needed(CGImageSourceCreateImageAtIndex(source,index,options), "roundtrip frame missing")
                    let bitmap = try needed(BitmapCopy.bitmapFrame(from:image), "roundtrip bitmap failed")
                    return try frameRecord(bitmap,index:index)
                }
            }
        }
        let equal = NSArray(array:expected).isEqual(to:actual)
        let report: [String:Any] = ["input":input.path,"output":output.path,
            "input_sha256":sha(try Data(contentsOf:input)),"output_sha256":sha(try Data(contentsOf:output)),
            "input_bytes":try Data(contentsOf:input).count,"output_bytes":try Data(contentsOf:output).count,
            "source_decode_wall_seconds":decoded-started,"encoding_wall_seconds":encoded-encodeStart,
            "all_frame_records_exactly_equal":equal,"frame_count":frames.count,
            "expected_frames":expected,"roundtrip_frames":actual,
            "playback_frame_duration_seconds":1.0/15.0,
            "os":ProcessInfo.processInfo.operatingSystemVersionString]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
        guard equal else { throw EncodingError(message:"lossless equivalence failed; candidate must not ship") }
    }
}
