import Foundation
import UniformTypeIdentifiers
import UIKit

struct PreparedImageAttachment {
    let data: Data
    let mimeType: String

    var userInput: AppUserInput {
        .image(url: dataURI)
    }

    var chatImage: ChatImage {
        ChatImage(data: data, mimeType: mimeType)
    }

    private var dataURI: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

enum ConversationAttachmentSupport {
    static let supportedImageFileContentTypes: [UTType] = [
        .png,
        .jpeg,
        .gif,
    ] + ["webp", "heic", "heif"].compactMap { UTType(filenameExtension: $0) }

    static let supportedFileContentTypes: [UTType] = [.data]

    static func prepareImage(_ image: UIImage) -> PreparedImageAttachment? {
        guard let encodedImage = encodedImageData(for: image) else { return nil }
        return PreparedImageAttachment(data: encodedImage.data, mimeType: encodedImage.mimeType)
    }

    static func loadImageFile(at url: URL) -> UIImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    static func loadPickedFile(at url: URL) -> PickedComposerFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if shouldLoadAsImageOnly(url) {
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else {
                return nil
            }
            return .image(image)
        }

        return .file(
            ComposerFileAttachment(
                label: fileLabel(for: url),
                path: url.path
            )
        )
    }

    static func buildTurnInputs(text: String, additionalInput: [AppUserInput]) -> [AppUserInput] {
        var inputs: [AppUserInput] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputs.append(.text(text: text, textElements: []))
        }
        inputs.append(contentsOf: additionalInput)
        return inputs
    }

    private static let maxTransportPixelDimension: CGFloat = 2048
    private static let minTransportPixelDimension: CGFloat = 1024
    private static let maxTransportImageBytes = 1_200_000
    private static let transportJpegQuality: CGFloat = 0.7

    private static func encodedImageData(for image: UIImage) -> (data: Data, mimeType: String)? {
        var current = downscaled(image, longestSide: maxTransportPixelDimension)
        if current.litterHasAlpha,
           let pngData = current.pngData(),
           pngData.count <= maxTransportImageBytes {
            return (pngData, "image/png")
        }
        var dimension = maxTransportPixelDimension
        while true {
            guard let jpegData = current.jpegData(compressionQuality: transportJpegQuality) else { break }
            if jpegData.count <= maxTransportImageBytes || dimension <= minTransportPixelDimension {
                return (jpegData, "image/jpeg")
            }
            dimension = max(dimension * 0.75, minTransportPixelDimension)
            current = downscaled(current, longestSide: dimension)
        }
        return current.pngData().map { ($0, "image/png") }
    }

    private static func downscaled(_ image: UIImage, longestSide limit: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longestSide = max(pixelWidth, pixelHeight)
        guard longestSide > limit else { return image }
        let ratio = limit / longestSide
        let targetSize = CGSize(width: pixelWidth * ratio, height: pixelHeight * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func isSupportedImageFile(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"].contains(pathExtension)
    }

    private static func shouldLoadAsImageOnly(_ url: URL) -> Bool {
        isSupportedImageFile(url) || isPhotosLibraryInternalURL(url)
    }

    static func isPhotosLibraryInternalURL(_ url: URL) -> Bool {
        isPhotosLibraryInternalPath(url.path)
    }

    static func isPhotosLibraryInternalPath(_ path: String) -> Bool {
        let path = path.lowercased()
        return path.contains(".photoslibrary/")
            || path.contains(".photoslibrary\\")
            || path.hasSuffix(".photoslibrary")
    }

    private static func fileLabel(for url: URL) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent
        if !baseName.isEmpty {
            return baseName
        }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}

enum PickedComposerFile {
    case image(UIImage)
    case file(ComposerFileAttachment)
}

private extension UIImage {
    var litterHasAlpha: Bool {
        guard let alphaInfo = cgImage?.alphaInfo else { return false }
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }
}
