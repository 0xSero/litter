import Foundation
import HairballUI
import Hairball

/// Manages per-item `StreamingMarkdownRenderer` instances so streaming deltas
/// flow through `append()` and the continuous token reveal works from the first
/// token.
@MainActor
final class StreamingRendererCoordinator {
    static let shared = StreamingRendererCoordinator()

    private var renderers: [String: StreamingMarkdownRenderer] = [:]
    private var activeItemId: String?

    // MARK: - Delta feeding

    func appendDelta(_ delta: String, for itemId: String) {
        if activeItemId != itemId {
            if let oldId = activeItemId {
                renderers[oldId]?.finish()
            }
            activeItemId = itemId
        }
        // Only append to an existing renderer. The first delta arrives via
        // `ThreadItemChanged` (placeholder insert) and never reaches this
        // path — the snapshot's text is updated instead. If we lazy-created
        // a renderer here, it would start empty and get only second-and-
        // later deltas; SwiftUI's later rebuild of the bubble would then
        // return that truncated renderer (its `currentText` seed is ignored
        // when a renderer already exists), dropping the first delta.
        // Letting this be a no-op when no renderer exists means the bubble
        // view's init seeds the renderer from the snapshot's full text.
        renderers[itemId]?.append(delta)
    }

    // MARK: - Renderer access

    func hasRenderer(for itemId: String) -> Bool {
        renderers[itemId] != nil
    }

    func existingRenderer(for itemId: String) -> StreamingMarkdownRenderer? {
        renderers[itemId]
    }

    func renderer(for itemId: String, currentText: String) -> StreamingMarkdownRenderer {
        if let existing = renderers[itemId] {
            return existing
        }
        let r = makeRenderer(for: itemId)
        if !currentText.isEmpty {
            r.append(currentText)
        }
        return r
    }

    func finish(itemId: String) {
        if let r = renderers.removeValue(forKey: itemId) {
            r.finish()
        }
    }

    // MARK: - Streaming lifecycle

    func finishActive() {
        for (_, r) in renderers {
            if !r.isFinished { r.finish() }
        }
        // Mounted bubbles retain their own renderer until SwiftUI replaces
        // them. The coordinator only owns renderers for the live turn.
        renderers.removeAll()
        activeItemId = nil
    }

    func reset() {
        finishActive()
    }

    // MARK: - Private

    private func makeRenderer(for itemId: String) -> StreamingMarkdownRenderer {
        let r = StreamingMarkdownRenderer(
            processors: [LatexTransformer()],
            throttleInterval: 0.016
        )
        renderers[itemId] = r
        return r
    }
}
