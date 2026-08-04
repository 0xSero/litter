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

    private static func encodedImageData(for image: UIImage) -> (data: Data, mimeType: String)? {
        if image.litterHasAlpha, let pngData = image.pngData() {
            return (pngData, "image/png")
        }
        if let jpegData = image.jpegData(compressionQuality: 0.85) {
            return (jpegData, "image/jpeg")
        }
        if let pngData = image.pngData() {
            return (pngData, "image/png")
        }
        return nil
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
