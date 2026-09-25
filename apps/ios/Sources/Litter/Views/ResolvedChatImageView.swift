import ImageIO
import SwiftUI
import UIKit
import WebKit

enum ResolvedChatImageSource: Equatable {
    case data(Data)
    case path(String)

    var cacheKey: String {
        switch self {
        case .data(let data):
            return "data-\(data.count)-\(data.hashValue)"
        case .path(let path):
            return "path-\(path)"
        }
    }
}

/// Renders chat images from either inline bytes or a path on the connected
/// Codex host. PNGs use UIKit; SVGs are displayed in a script-disabled WebKit
/// image context so vector artwork remains sharp without allowing document
/// scripts or external subresources to run.
struct ResolvedChatImageView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.activeThreadKey) private var activeThreadKey
    @Environment(\.activeThreadCwd) private var activeThreadCwd

    let source: ResolvedChatImageSource
    var serverId: String? = nil
    var cwd: String? = nil
    var maxHeight: CGFloat = 320

    @State private var imageData: Data?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var isSVGData = false
    @State private var decodedImage: UIImage?

    private static let dataCache = NSCache<NSString, NSData>()
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()
    /// Longest edge (pixels) for decoded raster previews. Transcript images
    /// are capped at `maxHeight` points, so full-resolution decodes only
    /// waste memory and main-thread time.
    private static let maxDecodePixelSize: CGFloat = 2048

    var body: some View {
        Group {
            if let imageData {
                if isSVGData {
                    SafeSVGImageView(data: imageData)
                        .aspectRatio(Self.svgAspectRatio(imageData), contentMode: .fit)
                } else if let image = decodedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .draggable(Image(uiImage: image)) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 120)
                        }
                } else {
                    imageError("Could not decode the image.")
                }
            } else if isLoading {
                ProgressView()
                    .tint(LitterTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                imageError(loadError ?? "Image unavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .center)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: taskKey) {
            await loadImage()
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var resolvedServerId: String {
        serverId ?? activeThreadKey?.serverId ?? ""
    }

    /// Falls back to the active thread's cwd, read from the environment
    /// rather than from `appModel.threadSnapshot(for:)`. This view is
    /// instantiated once per inline image in a transcript, so resolving the
    /// cwd through `AppModel` put one `snapshot` observation edge per image
    /// into `body` (via `taskKey`) — every one of them re-rendering at the
    /// ~8 fps streaming snapshot cadence. The cwd is injected once by the
    /// conversation host alongside `\.activeThreadKey`.
    private var resolvedCwd: String? {
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cwd
        }
        return activeThreadCwd
    }

    private var taskKey: String {
        "\(source.cacheKey)|\(resolvedServerId)|\(resolvedCwd ?? "<none>")"
    }

    private var accessibilityLabel: String {
        switch source {
        case .data:
            return "Assistant image"
        case .path(let path):
            return "Assistant image \((path as NSString).lastPathComponent)"
        }
    }

    @ViewBuilder
    private func imageError(_ message: String) -> some View {
        Text(message)
            .litterFont(.caption)
            .foregroundColor(LitterTheme.danger)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 24)
    }

    private func loadImage() async {
        let key = taskKey as NSString
        if let cached = Self.dataCache.object(forKey: key) {
            let data = cached as Data
            let svg = Self.isSVG(data, source: source)
            if !svg, Self.imageCache.object(forKey: key) == nil {
                if let image = await Self.decodeOffMain(data) {
                    Self.imageCache.setObject(image, forKey: key)
                }
            }
            isSVGData = svg
            decodedImage = svg ? nil : Self.imageCache.object(forKey: key)
            imageData = data
            loadError = nil
            isLoading = false
            return
        }

        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let data: Data
            switch source {
            case .data(let inlineData):
                data = inlineData
            case .path(let path):
                let resolved = try await appModel.client.resolveImageViewAt(
                    serverId: resolvedServerId,
                    path: path,
                    cwd: resolvedCwd
                )
                data = Data(resolved.bytes)
            }

            guard !data.isEmpty else {
                throw ResolvedChatImageError.emptyImage
            }
            let svg = Self.isSVG(data, source: source)
            var image: UIImage?
            if !svg {
                image = await Self.decodeOffMain(data)
                if let image { Self.imageCache.setObject(image, forKey: key) }
            }
            Self.dataCache.setObject(data as NSData, forKey: key)
            isSVGData = svg
            decodedImage = image
            imageData = data
        } catch {
            imageData = nil
            decodedImage = nil
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            loadError = message.isEmpty ? "Image unavailable" : message
        }
    }

    /// Decodes (and downsamples) raster bytes off the main actor via ImageIO.
    /// Falls back to `UIImage(data:)` for formats ImageIO can't thumbnail.
    private static func decodeOffMain(_ data: Data) async -> UIImage? {
        let maxPixel = maxDecodePixelSize
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            if let imageSource = CGImageSourceCreateWithData(data as CFData, sourceOptions) {
                let thumbOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                ] as [CFString: Any] as CFDictionary
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions) {
                    return UIImage(cgImage: cgImage)
                }
            }
            guard let fallback = UIImage(data: data) else { return nil }
            return fallback.preparingForDisplay() ?? fallback
        }.value
    }

    private static func isSVG(_ data: Data, source: ResolvedChatImageSource) -> Bool {
        if case .path(let path) = source {
            var normalizedPath = path.lowercased()
            if let fragmentIndex = normalizedPath.firstIndex(of: "#") {
                normalizedPath = String(normalizedPath[..<fragmentIndex])
            }
            if let queryIndex = normalizedPath.firstIndex(of: "?") {
                normalizedPath = String(normalizedPath[..<queryIndex])
            }
            if normalizedPath.hasSuffix(".svg") {
                return true
            }
        }
        guard let prefix = String(data: data.prefix(2048), encoding: .utf8)?.lowercased() else {
            return false
        }
        return prefix.contains("<svg")
    }

    private static let viewBoxRegex: NSRegularExpression = {
        let pattern = #"viewBox\s*=\s*[\"']\s*[-+0-9.eE]+[\s,]+[-+0-9.eE]+[\s,]+([-+0-9.eE]+)[\s,]+([-+0-9.eE]+)\s*[\"']"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func svgAspectRatio(_ data: Data) -> CGFloat {
        guard let source = String(data: data.prefix(8192), encoding: .utf8) else {
            return 16 / 9
        }
        guard let match = viewBoxRegex.firstMatch(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        ),
        let widthRange = Range(match.range(at: 1), in: source),
        let heightRange = Range(match.range(at: 2), in: source),
        let width = Double(source[widthRange]),
        let height = Double(source[heightRange]),
        width > 0,
        height > 0 else {
            return 16 / 9
        }
        return CGFloat(width / height)
    }
}

// MARK: - Active Thread Cwd Environment

/// Working directory of the thread currently on screen. Injected by the
/// conversation host next to `\.activeThreadKey` so per-message views can
/// resolve relative image paths without reading `AppModel.snapshot` (which
/// churns at the streaming snapshot cadence).
private struct ActiveThreadCwdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var activeThreadCwd: String? {
        get { self[ActiveThreadCwdKey.self] }
        set { self[ActiveThreadCwdKey.self] = newValue }
    }
}

extension View {
    func activeThreadCwd(_ cwd: String?) -> some View {
        environment(\.activeThreadCwd, cwd)
    }
}

private enum ResolvedChatImageError: LocalizedError {
    case emptyImage

    var errorDescription: String? {
        "Image data was empty."
    }
}

private struct SafeSVGImageView: UIViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let fingerprint = "\(data.count)-\(data.hashValue)"
        guard context.coordinator.fingerprint != fingerprint else { return }
        context.coordinator.fingerprint = fingerprint

        let payload = data.base64EncodedString()
        let html = """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent}img{display:block;width:100%;height:100%;object-fit:contain}</style>
        </head><body><img alt="" src="data:image/svg+xml;base64,\(payload)"></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var fingerprint: String?
    }
}
