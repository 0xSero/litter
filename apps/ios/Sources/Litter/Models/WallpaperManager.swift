import SwiftUI
import Observation
import UIKit
import HairballUI

// MARK: - Types

enum WallpaperType: String, Codable {
    case none
    case theme
    case customImage = "custom_image"
    case solidColor = "solid_color"
    case customVideo = "custom_video"
    case videoUrl = "video_url"
}

enum WallpaperScope: Equatable {
    case thread(ThreadKey)
    case server(String)
}

enum PatternType: Int, CaseIterable {
    case dotGrid
    case diagonalLines
    case concentricCircles
    case hexagonalMesh
    case crossHatch
    case waveLines
}

struct WallpaperConfig: Codable, Equatable {
    var type: WallpaperType = .none
    var themeSlug: String?
    var colorHex: String?
    var blur: Double = 0.0
    var brightness: Double = 1.0
    var motionEnabled: Bool = false
    var videoURL: String?
    var videoDuration: Double?
}

enum GranularityKind: String, CaseIterable, Identifiable {
    case character = "Character"
    case chunk8 = "Chunk (8)"
    case chunk32 = "Chunk (32)"
    case line = "Line"
    case block = "Block"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .character: return "Char"
        case .chunk8: return "8"
        case .chunk32: return "32"
        case .line: return "Line"
        case .block: return "Block"
        }
    }

    var granularity: RevealGranularity {
        switch self {
        case .character: return .character
        case .chunk8: return .chunk(8)
        case .chunk32: return .chunk(32)
        case .line: return .line
        case .block: return .block
        }
    }
}

struct TypingEffectConfig: Codable, Equatable, Hashable {
    var effects: [String] = []
    var revealDuration: Double = 0.03
    var granularity: String = "Block"
    var revealMode: String = "Linear"

    /// Preserve the cadence delivered by the model. Decorative per-character
    /// reveal made a fast SSE stream look delayed and choppy, especially when
    /// reasoning and tool rows were interleaved with assistant text.
    static let `default` = TypingEffectConfig()

    var activeEffect: StreamingEffectKind? {
        effects.first.flatMap { StreamingEffectKind(rawValue: $0) }
    }

    var resolvedEffect: (any StreamingTextEffect)? {
        activeEffect?.effect
    }

    var effectiveRevealMode: TokenRevealMode {
        revealMode == "Continuous" ? .continuous : .linear
    }

    var effectiveGranularity: RevealGranularity {
        (GranularityKind(rawValue: granularity) ?? .block).granularity
    }
}

// MARK: - JSON Storage

private struct WallpaperPrefsFile: Codable {
    var threads: [String: WallpaperConfig] = [:]
    var servers: [String: WallpaperConfig] = [:]
    var typingEffectThreads: [String: TypingEffectConfig] = [:]
    var typingEffectServers: [String: TypingEffectConfig] = [:]
}

// MARK: - WallpaperManager

@MainActor
@Observable
final class WallpaperManager {
    @MainActor static let shared = WallpaperManager()

    var activeThreadKey: ThreadKey?
    private(set) var resolvedWallpaperImage: UIImage?
    private(set) var resolvedConfig: WallpaperConfig?
    private(set) var version: Int = 0

    @ObservationIgnored
    private var prefs = WallpaperPrefsFile()

    @ObservationIgnored
    private var imageCache: [String: UIImage] = [:]

    @ObservationIgnored
    private static let prefsFileName = "wallpaper_prefs.json"

    @ObservationIgnored
    private static var prefsFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(prefsFileName)
    }

    @ObservationIgnored
    private static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    // Legacy compat — some views still check this
    var wallpaperImage: UIImage? { resolvedWallpaperImage }
    var isWallpaperSet: Bool { resolvedConfig != nil && resolvedConfig?.type != WallpaperType.none }

    private init() {
        loadPrefs()
    }

    // MARK: - Public API

    func resolveConfig(for threadKey: ThreadKey?) -> WallpaperConfig? {
        guard let key = threadKey else { return nil }

        // Thread-specific
        let threadScopeKey = scopeKey(for: .thread(key))
        if let cfg = prefs.threads[threadScopeKey], cfg.type != .none {
            return cfg
        }

        // Server default
        let serverScopeKey = key.serverId
        if let cfg = prefs.servers[serverScopeKey], cfg.type != .none {
            return cfg
        }

        return nil
    }

    func resolveScope(for threadKey: ThreadKey?) -> WallpaperScope? {
        guard let key = threadKey else { return nil }

        let threadScopeKey = scopeKey(for: .thread(key))
        if let cfg = prefs.threads[threadScopeKey], cfg.type != .none {
            return .thread(key)
        }

        if let cfg = prefs.servers[key.serverId], cfg.type != .none {
            return .server(key.serverId)
        }

        return nil
    }

    func resolveConfigForServer(_ serverId: String) -> WallpaperConfig? {
        if let cfg = prefs.servers[serverId], cfg.type != .none {
            return cfg
        }
        return nil
    }

    func setWallpaper(_ config: WallpaperConfig, scope: WallpaperScope) {
        switch scope {
        case .thread(let key):
            let k = scopeKey(for: .thread(key))
            if config.type == .none {
                prefs.threads.removeValue(forKey: k)
            } else {
                prefs.threads[k] = config
            }
        case .server(let serverId):
            if config.type == .none {
                prefs.servers.removeValue(forKey: serverId)
            } else {
                prefs.servers[serverId] = config
            }
        }
        savePrefs()
        refreshResolved()
    }

    func setCustomImage(_ image: UIImage, scope: WallpaperScope) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }

        let fileName: String
        switch scope {
        case .thread(let key):
            fileName = "wallpaper_thread_\(key.serverId)_\(key.threadId).jpg"
        case .server(let serverId):
            fileName = "wallpaper_server_\(serverId).jpg"
        }

        let fileURL = Self.documentsDir.appendingPathComponent(fileName)
        try? data.write(to: fileURL, options: .atomic)

        var config = WallpaperConfig(type: .customImage)
        config.blur = 0.0
        config.brightness = 1.0
        setWallpaper(config, scope: scope)
    }

    // MARK: - Typing Effect

    func resolveTypingEffect(for threadKey: ThreadKey?) -> TypingEffectConfig {
        guard let key = threadKey else { return .default }

        let threadScopeKey = scopeKey(for: .thread(key))
        if let cfg = prefs.typingEffectThreads[threadScopeKey] {
            return cfg
        }

        if let cfg = prefs.typingEffectServers[key.serverId] {
            return cfg
        }

        return .default
    }

    func resolveTypingEffectForServer(_ serverId: String) -> TypingEffectConfig {
        prefs.typingEffectServers[serverId] ?? .default
    }

    func setTypingEffect(_ config: TypingEffectConfig, scope: WallpaperScope) {
        switch scope {
        case .thread(let key):
            let k = scopeKey(for: .thread(key))
            prefs.typingEffectThreads[k] = config
        case .server(let serverId):
            prefs.typingEffectServers[serverId] = config
        }
        savePrefs()
        version += 1
    }

    func setActiveThreadKey(_ key: ThreadKey?) {
        guard activeThreadKey != key else { return }
        activeThreadKey = key
        refreshResolved()
    }

    func cleanup(knownServerIds: Set<String>, knownThreadKeys: Set<String>) {
        var changed = false

        for key in prefs.threads.keys {
            if !knownThreadKeys.contains(key) {
                prefs.threads.removeValue(forKey: key)
                // Remove orphaned image and video files
                let parts = key.split(separator: ":")
                if parts.count == 2 {
                    for ext in ["jpg", "mp4"] {
                        let fileName = "wallpaper_thread_\(parts[0])_\(parts[1]).\(ext)"
                        let fileURL = Self.documentsDir.appendingPathComponent(fileName)
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }
                changed = true
            }
        }

        for serverId in prefs.servers.keys {
            if !knownServerIds.contains(serverId) {
                prefs.servers.removeValue(forKey: serverId)
                for ext in ["jpg", "mp4"] {
                    let fileName = "wallpaper_server_\(serverId).\(ext)"
                    let fileURL = Self.documentsDir.appendingPathComponent(fileName)
                    try? FileManager.default.removeItem(at: fileURL)
                }
                changed = true
            }
        }

        for key in prefs.typingEffectThreads.keys where !knownThreadKeys.contains(key) {
            prefs.typingEffectThreads.removeValue(forKey: key)
            changed = true
        }
        for serverId in prefs.typingEffectServers.keys where !knownServerIds.contains(serverId) {
            prefs.typingEffectServers.removeValue(forKey: serverId)
            changed = true
        }

        if changed {
            savePrefs()
        }
    }

    // MARK: - Wallpaper Image Generation

    func generateWallpaper(themeSlug: String, themeManager: ThemeManager) -> UIImage? {
        if let cached = imageCache[themeSlug] { return cached }

        guard let entry = themeManager.themeIndex.first(where: { $0.slug == themeSlug }) else {
            return nil
        }

        let bgColor = UIColor(Color(hex: entry.backgroundHex))
        let accentColor = UIColor(Color(hex: entry.accentHex))
        let patternIndex = abs(themeSlug.hashValue) % PatternType.allCases.count
        let pattern = PatternType.allCases[patternIndex]

        let size = CGSize(width: 390, height: 844) // Standard phone size
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            bgColor.setFill()
            ctx.fill(rect)

            let patternColor = accentColor.withAlphaComponent(0.10)
            patternColor.setStroke()
            patternColor.setFill()

            let context = ctx.cgContext
            context.setLineWidth(1.0)

            switch pattern {
            case .dotGrid:
                drawDotGrid(in: context, size: size, color: patternColor)
            case .diagonalLines:
                drawDiagonalLines(in: context, size: size, color: patternColor)
            case .concentricCircles:
                drawConcentricCircles(in: context, size: size, color: patternColor)
            case .hexagonalMesh:
                drawHexagonalMesh(in: context, size: size, color: patternColor)
            case .crossHatch:
                drawCrossHatch(in: context, size: size, color: patternColor)
            case .waveLines:
                drawWaveLines(in: context, size: size, color: patternColor)
            }
        }

        imageCache[themeSlug] = image
        return image
    }

    func generateThumbnail(for entry: ThemeIndexEntry) -> UIImage {
        let bgColor = UIColor(Color(hex: entry.backgroundHex))
        let accentColor = UIColor(Color(hex: entry.accentHex))
        let patternIndex = abs(entry.slug.hashValue) % PatternType.allCases.count
        let pattern = PatternType.allCases[patternIndex]

        let size = CGSize(width: 80, height: 120)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            bgColor.setFill()
            ctx.fill(rect)

            let patternColor = accentColor.withAlphaComponent(0.12)
            patternColor.setStroke()
            patternColor.setFill()

            let context = ctx.cgContext
            context.setLineWidth(0.5)

            switch pattern {
            case .dotGrid:
                drawDotGrid(in: context, size: size, color: patternColor)
            case .diagonalLines:
                drawDiagonalLines(in: context, size: size, color: patternColor)
            case .concentricCircles:
                drawConcentricCircles(in: context, size: size, color: patternColor)
            case .hexagonalMesh:
                drawHexagonalMesh(in: context, size: size, color: patternColor)
            case .crossHatch:
                drawCrossHatch(in: context, size: size, color: patternColor)
            case .waveLines:
                drawWaveLines(in: context, size: size, color: patternColor)
            }
        }
    }

    func wallpaperImage(for config: WallpaperConfig?, scope: WallpaperScope?, themeManager: ThemeManager) -> UIImage? {
        guard let config = config else { return nil }

        switch config.type {
        case .none:
            return nil
        case .theme:
            guard let slug = config.themeSlug else { return nil }
            return generateWallpaper(themeSlug: slug, themeManager: themeManager)
        case .customImage:
            return loadCustomImage(for: scope)
        case .solidColor:
            guard let hex = config.colorHex else { return nil }
            return generateSolidColor(hex: hex)
        case .customVideo, .videoUrl:
            return nil
        }
    }

    // MARK: - Private Helpers

    private func scopeKey(for scope: WallpaperScope) -> String {
        switch scope {
        case .thread(let key):
            return "\(key.serverId)::\(key.threadId)"
        case .server(let serverId):
            return serverId
        }
    }

    private func refreshResolved() {
        version += 1
        resolvedConfig = resolveConfig(for: activeThreadKey)
        // Image resolution is deferred to view layer which has themeManager access
        if resolvedConfig == nil || resolvedConfig?.type == WallpaperType.none {
            resolvedWallpaperImage = nil
        }
    }

    func updateResolvedImage(_ image: UIImage?) {
        resolvedWallpaperImage = image
    }

    func videoFileURL(for scope: WallpaperScope) -> URL {
        let fileName: String
        switch scope {
        case .thread(let key):
            fileName = "wallpaper_thread_\(key.serverId)_\(key.threadId).mp4"
        case .server(let serverId):
            fileName = "wallpaper_server_\(serverId).mp4"
        }
        return Self.documentsDir.appendingPathComponent(fileName)
    }

    private func loadCustomImage(for scope: WallpaperScope?) -> UIImage? {
        guard let scope = scope else { return nil }
        let fileName: String
        switch scope {
        case .thread(let key):
            fileName = "wallpaper_thread_\(key.serverId)_\(key.threadId).jpg"
        case .server(let serverId):
            fileName = "wallpaper_server_\(serverId).jpg"
        }
        let fileURL = Self.documentsDir.appendingPathComponent(fileName)
        return UIImage(contentsOfFile: fileURL.path)
    }

    private func generateSolidColor(hex: String) -> UIImage {
        let color = UIColor(Color(hex: hex))
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - JSON Persistence

    private func loadPrefs() {
        let url = Self.prefsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            prefs = try JSONDecoder().decode(WallpaperPrefsFile.self, from: data)
        } catch {
            LLog.error("wallpaper", "failed to load wallpaper prefs", error: error)
        }
    }

    private func savePrefs() {
        do {
            let data = try JSONEncoder().encode(prefs)
            try data.write(to: Self.prefsFileURL, options: .atomic)
        } catch {
            LLog.error("wallpaper", "failed to save wallpaper prefs", error: error)
        }
    }

    // MARK: - Pattern Drawing

    private func drawDotGrid(in context: CGContext, size: CGSize, color: UIColor) {
        let spacing: CGFloat = 20
        let radius: CGFloat = 2
        color.setFill()
        var y: CGFloat = spacing / 2
        while y < size.height {
            var x: CGFloat = spacing / 2
            while x < size.width {
                context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
    }

    private func drawDiagonalLines(in context: CGContext, size: CGSize, color: UIColor) {
        let spacing: CGFloat = 16
        color.setStroke()
        context.setLineWidth(1.0)
        let total = size.width + size.height
        var offset: CGFloat = -size.height
        while offset < total {
            context.move(to: CGPoint(x: offset, y: 0))
            context.addLine(to: CGPoint(x: offset + size.height, y: size.height))
            offset += spacing
        }
        context.strokePath()
    }

    private func drawConcentricCircles(in context: CGContext, size: CGSize, color: UIColor) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = max(size.width, size.height)
        let spacing: CGFloat = 24
        color.setStroke()
        context.setLineWidth(0.8)
        var r: CGFloat = spacing
        while r < maxRadius {
            context.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            r += spacing
        }
        context.strokePath()
    }

    private func drawHexagonalMesh(in context: CGContext, size: CGSize, color: UIColor) {
        let hexSize: CGFloat = 18
        let w = hexSize * 2
        let h = sqrt(3) * hexSize
        color.setStroke()
        context.setLineWidth(0.8)

        var row = 0
        var y: CGFloat = 0
        while y < size.height + h {
            let xOffset: CGFloat = (row % 2 == 0) ? 0 : w * 0.75
            var x: CGFloat = xOffset
            while x < size.width + w {
                drawHexagon(in: context, center: CGPoint(x: x, y: y), size: hexSize)
                x += w * 1.5
            }
            y += h / 2
            row += 1
        }
        context.strokePath()
    }

    private func drawHexagon(in context: CGContext, center: CGPoint, size: CGFloat) {
        for i in 0..<6 {
            let angle = CGFloat.pi / 3 * CGFloat(i) - CGFloat.pi / 6
            let point = CGPoint(x: center.x + size * cos(angle), y: center.y + size * sin(angle))
            if i == 0 {
                context.move(to: point)
            } else {
                context.addLine(to: point)
            }
        }
        context.closePath()
    }

    private func drawCrossHatch(in context: CGContext, size: CGSize, color: UIColor) {
        let spacing: CGFloat = 16
        color.setStroke()
        context.setLineWidth(0.8)

        // Forward diagonals
        let total = size.width + size.height
        var offset: CGFloat = -size.height
        while offset < total {
            context.move(to: CGPoint(x: offset, y: 0))
            context.addLine(to: CGPoint(x: offset + size.height, y: size.height))
            offset += spacing
        }
        // Backward diagonals
        offset = 0
        while offset < total {
            context.move(to: CGPoint(x: offset, y: 0))
            context.addLine(to: CGPoint(x: offset - size.height, y: size.height))
            offset += spacing
        }
        context.strokePath()
    }

    private func drawWaveLines(in context: CGContext, size: CGSize, color: UIColor) {
        let spacing: CGFloat = 20
        let amplitude: CGFloat = 6
        let wavelength: CGFloat = 40
        color.setStroke()
        context.setLineWidth(0.8)

        var y: CGFloat = spacing / 2
        while y < size.height {
            context.move(to: CGPoint(x: 0, y: y))
            var x: CGFloat = 0
            while x <= size.width {
                let dy = sin(x / wavelength * 2 * .pi) * amplitude
                context.addLine(to: CGPoint(x: x, y: y + dy))
                x += 2
            }
            y += spacing
        }
        context.strokePath()
    }
}
