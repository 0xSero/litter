import AVFoundation
import UIKit

/// Transcodes, validates, and generates thumbnails for video wallpapers.
final class VideoWallpaperProcessor {

    enum ProcessorError: LocalizedError {
        case durationExceedsLimit(Double)
        case noVideoTrack
        case transcodeFailed(String)
        case downloadFailed(String)
        case fileTooLarge(Int64)

        var errorDescription: String? {
            switch self {
            case .durationExceedsLimit(let duration):
                return "Video is \(Int(duration))s — maximum is 30s"
            case .noVideoTrack:
                return "No video track found"
            case .transcodeFailed(let reason):
                return "Transcode failed: \(reason)"
            case .downloadFailed(let reason):
                return "Download failed: \(reason)"
            case .fileTooLarge(let bytes):
                return "Video is \(bytes / 1_000_000)MB — maximum is 50MB"
            }
        }
    }

    static let maxDuration: Double = 30.0
    static let maxFileSize: Int64 = 50_000_000 // 50 MB

    // MARK: - Public API

    /// Transcode a local video file to a wallpaper-ready MP4 at the given destination.
    /// Returns the duration of the transcoded video.
    static func transcode(source: URL, destination: URL) async throws -> Double {
        let asset = AVURLAsset(url: source)

        // Validate duration
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        guard duration <= maxDuration else {
            throw ProcessorError.durationExceedsLimit(duration)
        }

        // Build a composition with only the video track (strip audio)
        let composition = AVMutableComposition()
        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessorError.noVideoTrack
        }

        let sourceDuration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: sourceDuration)

        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ProcessorError.transcodeFailed("Could not create composition track")
        }

        try compositionTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)

        // Copy the preferred transform so orientation is preserved
        let transform = try await sourceVideoTrack.load(.preferredTransform)
        compositionTrack.preferredTransform = transform

        // Export
        // Remove existing file at destination
        try? FileManager.default.removeItem(at: destination)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetMediumQuality
        ) else {
            throw ProcessorError.transcodeFailed("Could not create export session")
        }

        exportSession.shouldOptimizeForNetworkUse = true

        try await exportSession.export(to: destination, as: .mp4)

        // Validate file size
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        if fileSize > maxFileSize {
            try? FileManager.default.removeItem(at: destination)
            throw ProcessorError.fileTooLarge(fileSize)
        }
        return duration
    }

    /// Download a remote video URL to a temporary file, then transcode to the destination.
    /// Returns the duration of the transcoded video.
    static func downloadAndTranscode(remoteURL: URL, destination: URL) async throws -> Double {
        let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ProcessorError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }

        return try await transcode(source: tempURL, destination: destination)
    }

    /// Generate a thumbnail image from the first frame of a video file.
    static func generateThumbnail(for videoURL: URL) async -> UIImage? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)

        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage)
        } catch {
            LLog.error("wallpaper", "failed to generate video thumbnail", error: error)
            return nil
        }
    }
}
