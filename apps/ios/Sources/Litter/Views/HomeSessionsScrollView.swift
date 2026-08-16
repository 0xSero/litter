import AVKit
import ImageIO
import SwiftUI
import UIKit

// MARK: - SwiftUI entry point

/// UIKit-backed scroll view for the home dashboard's session list. Owns
/// pinch-to-zoom, horizontal row swipes, and vertical scroll directly so
/// gestures never fight each other (the SwiftUI `MagnifyGesture` +
/// `ScrollView` combo jittered because both consumed the same pan
/// deltas). Row content stays SwiftUI — each row hosts
/// `HomeSessionRowContent` inside a `UIHostingController`. UIKit animates
/// only the row's *container height* during a pinch, so SwiftUI does no
/// per-tick work.
struct HomeSessionsScrollView: UIViewRepresentable {
    struct Callbacks {
        var onOpen: (HomeDashboardRecentSession) -> Void
        var onReply: (HomeDashboardRecentSession) -> Void
        var onHide: (ThreadKey) -> Void
        var onPin: (ThreadKey) -> Void
        var onUnpin: (ThreadKey) -> Void
        var onCancelTurn: (HomeDashboardRecentSession) -> Void
        var onDelete: (HomeDashboardRecentSession) -> Void
        var onFork: (HomeDashboardRecentSession) -> Void
        var onShowPiP: (HomeDashboardRecentSession) -> Void
    }

    let sessions: [HomeDashboardRecentSession]
    let pinnedThreadKeys: Set<SavedThreadsStore.PinnedKey>
    let hydratingKeys: Set<String>
    let cancellingKeys: Set<String>
    let openingKey: ThreadKey?
    @Binding var zoomLevel: Int
    let showCatFooter: Bool
    let topInset: CGFloat
    let bottomInset: CGFloat
    let callbacks: Callbacks
    /// App's text scale from `@Environment(\.textScale)`. Piped in so
    /// row height measurements (which depend on rendered font sizes)
    /// can be invalidated when the user changes their text size in
    /// Appearance settings. Pass this in from the caller with
    /// `@Environment(\.textScale) private var textScale`.
    @Environment(\.textScale) private var textScale
    @Environment(ThemeManager.self) private var themeManager
    @Environment(WallpaperManager.self) private var wallpaperManager

    func makeUIView(context: Context) -> HomeSessionsScrollUIView {
        HomeSessionsScrollUIView()
    }

    func updateUIView(_ view: HomeSessionsScrollUIView, context: Context) {
        view.zoomCommit = { newZoom in
            if zoomLevel != newZoom { zoomLevel = newZoom }
        }
        // Propagate the SwiftUI `\.textScale` environment through the
        // hosting boundary. Without this, changing text size in settings
        // alters the rendered SwiftUI layout but the hosted controllers
        // inside each row wouldn't inherit the new value (UIHostingController
        // does not forward parent environment into its own tree).
        view.apply(
            sessions: sessions,
            pinnedThreadKeys: pinnedThreadKeys,
            hydratingKeys: hydratingKeys,
            cancellingKeys: cancellingKeys,
            openingKey: openingKey,
            zoomLevel: zoomLevel,
            showCatFooter: showCatFooter,
            topInset: topInset,
            bottomInset: bottomInset,
            textScale: textScale,
            themeManager: themeManager,
            wallpaperManager: wallpaperManager,
            callbacks: callbacks
        )
    }
}

// MARK: - Zoom height anchors

/// Fixed height anchors for zoom levels 1, 2, and 3 (fallback only —
/// the row's own `forceMeasureHostHeight` supersedes these when the row
/// is actually rendered at that zoom). Zoom 4 is always per-row
/// measured because its content height varies wildly with the assistant
/// response preview.
private enum ZoomHeights {
    static let z1: CGFloat = 28
    static let z2: CGFloat = 54
    static let z3: CGFloat = 110
    static let z4Minimum: CGFloat = 120
}

/// Zoom levels per "octave" of pinch (doubling/halving the finger
/// distance). Symmetric around scale=1, unlike `(scale - 1) / k` which
/// treats pinch-out (close) much less sensitively than pinch-in (open).
/// `log2(scale) * zoomLevelsPerOctave` gives: scale=2 → +1.4 levels,
/// scale=0.5 → -1.4 levels.
private let zoomLevelsPerOctave: Double = 1.4
private let zoomSnapDuration: TimeInterval = 0.22

// MARK: - Scroll view

/// CADisplayLink target shim — it only holds a closure to call on
/// each tick. `CADisplayLink` needs an ObjC @objc selector target,
/// which a generic closure-friendly helper provides cleanly.
private final class PinchBlurFadeTarget {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func tick() { handler() }
}

/// Vertical top+bottom vignette drawn over the scroll view during a
/// pinch. Fades in on `.began`, fades out on snap complete. Adds a
/// subtle "zooming in the center of the stack" feel — rows near the
/// vertical center of the screen stay bright, rows near the top/bottom
/// edges dim out.
private final class PinchVignetteView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let g = layer as! CAGradientLayer
        g.startPoint = CGPoint(x: 0.5, y: 0)
        g.endPoint = CGPoint(x: 0.5, y: 1)
        g.colors = [
            UIColor.black.withAlphaComponent(0.35).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.35).cgColor,
        ]
        g.locations = [0, 0.35, 0.65, 1]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class HomeSessionsScrollUIView: UIView {
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let pinchVignette = PinchVignetteView()
    private let catFooterHostingController = UIHostingController(rootView: AnyView(EmptyView()))
    private var containers: [ThreadKey: HomeRowContainer] = [:]
    private var order: [ThreadKey] = []

    private(set) var zoomLevel: Int = 2
    private(set) var isPinching = false
    private var continuousZoom: Double = 2.0
    private var pinchStartZoom: Double = 2.0
    private var pinchStartScale: CGFloat = 1.0
    private var pinchAnchorIdx: Int = 0
    private var pinchAnchorFraction: CGFloat = 0
    /// Last finger midpoint observed in `.changed`. By the time
    /// `.ended` fires, UIKit has typically already removed the touches
    /// — so we can't read the midpoint off the recognizer — but we
    /// need it for the drop anchor calculation.
    private var lastPinchMidpoint: CGPoint = .zero
    /// Finger midpoint captured at `.began`. The anchor row is pinned
    /// to THIS screen position for the duration of the gesture, so
    /// incidental finger drift during the pinch doesn't drag the
    /// content around like a scroll.
    private var pinchStartMidpoint: CGPoint = .zero

    private(set) var topInsetValue: CGFloat = 0
    private(set) var bottomInsetValue: CGFloat = 0
    private var catFooterCountEligible = false
    private var catFooterHostVisible = false
    private var catFooterEntranceStarted = false
    private var widthUsed: CGFloat = 0
    private var lastCommittedInteger: Int = 2
    /// Last-seen text scale. A change here invalidates every row's
    /// measured natural height because font sizes — and therefore
    /// intrinsic SwiftUI layout — shift with the user's text-size
    /// preference.
    private var lastTextScale: CGFloat = 0

    var zoomCommit: ((Int) -> Void)?

    /// Surface the scroll view's safe-area top for row containers — they
    /// need it to keep the previous card's bottom from peeking into the
    /// dynamic-island zone during page-fit transitions.
    var scrollViewSafeAreaTop: CGFloat { scrollView.safeAreaInsets.top }

    // Used by row containers to know whether to short-circuit tap/swipe.
    var pinchActive: Bool { isPinching }
    // Used by rows to lock the vertical scroll while a swipe is latched.
    private(set) var activeSwipeRowCount: Int = 0 {
        didSet { updateScrollEnabled() }
    }

    private lazy var pinchRecognizer: UIPinchGestureRecognizer = {
        let g = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        g.delegate = self
        return g
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scrollView.addSubview(contentView)
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = .clear
        scrollView.keyboardDismissMode = .interactive
        // `.always` so the scroll view's adjustedContentInset stacks
        // our configured `contentInset` on top of the safe-area insets
        // — lets the outer `.ignoresSafeArea()` SwiftUI modifier push
        // the scroll view edge-to-edge without the top row sliding
        // under the dynamic island / status bar.
        scrollView.contentInsetAdjustmentBehavior = .always
        scrollView.delegate = self
        scrollView.addGestureRecognizer(pinchRecognizer)
        catFooterHostingController.view.backgroundColor = .clear
        catFooterHostingController.view.isHidden = true
        contentView.addSubview(catFooterHostingController.view)
        // Let pinch and scroll pan arbitrate naturally. Pinch requires 2
        // touches to begin; `numberOfTouchesRequired = 2` on pinch + our
        // pinchActive check (which disables `scrollView.isScrollEnabled`
        // during a pinch) prevents them from fighting. Using
        // `panGestureRecognizer.require(toFail: pinchRecognizer)` left
        // 1-finger scrolls blocked until the pinch recognizer formally
        // failed — visible as dead touches on the row content area.

        // Vignette sits above the scroll view, edge-to-edge, non-
        // interactive. Fades in during pinch.
        pinchVignette.alpha = 0
        addSubview(pinchVignette)
        pinchVignette.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pinchVignette.topAnchor.constraint(equalTo: topAnchor),
            pinchVignette.leadingAnchor.constraint(equalTo: leadingAnchor),
            pinchVignette.trailingAnchor.constraint(equalTo: trailingAnchor),
            pinchVignette.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - widthUsed) > 0.5 {
            widthUsed = bounds.width
            invalidateMeasurements()
            relayout(animated: false)
        }
    }

    fileprivate func noteRowSwipeChanged(activated: Bool) {
        if activated { activeSwipeRowCount += 1 }
        else { activeSwipeRowCount = max(0, activeSwipeRowCount - 1) }
    }

    private func updateScrollEnabled() {
        let enabled = !(isPinching || activeSwipeRowCount > 0)
        scrollView.isScrollEnabled = enabled
        // Do not toggle `panGestureRecognizer.isEnabled` here. UIKit can
        // cancel a row's long-press recognizer when the pan recognizer is
        // disabled, skipping the row's normal cleanup and leaving the list
        // permanently locked. `isScrollEnabled` is sufficient to freeze the
        // offset while a committed horizontal swipe or pinch is active.
    }

    private func invalidateMeasurements() {
        for container in containers.values {
            container.invalidateNaturalHeight()
        }
    }

    // MARK: - Update

    func apply(
        sessions: [HomeDashboardRecentSession],
        pinnedThreadKeys: Set<SavedThreadsStore.PinnedKey>,
        hydratingKeys: Set<String>,
        cancellingKeys: Set<String>,
        openingKey: ThreadKey?,
        zoomLevel: Int,
        showCatFooter: Bool,
        topInset: CGFloat,
        bottomInset: CGFloat,
        textScale: CGFloat,
        themeManager: ThemeManager,
        wallpaperManager: WallpaperManager,
        callbacks: HomeSessionsScrollView.Callbacks
    ) {
        let zoomChanged = self.zoomLevel != zoomLevel && !isPinching
        let enteredPageFit = zoomChanged && zoomLevel == 4
        self.zoomLevel = zoomLevel
        if !isPinching {
            self.continuousZoom = Double(zoomLevel)
        }
        self.lastCommittedInteger = zoomLevel
        // Zoom 4 = page-fit. Snappier deceleration so the snap-to-page
        // arrives quickly instead of drifting like a normal long scroll.
        scrollView.decelerationRate = (zoomLevel == 4) ? .fast : .normal
        self.topInsetValue = topInset
        self.bottomInsetValue = bottomInset
        self.catFooterCountEligible = showCatFooter && !sessions.isEmpty && sessions.count <= 10
        // At zoom 4 each card *frame* is the full scroll-view height,
        // and the card's internal layout puts the title below the top
        // chrome via fixed offsets in `HomeRowContainer.layoutSubviews`.
        // We zero out both content insets so the scroll view's natural
        // rest position has card 0's frame top at bounds.y == 0 — i.e.
        // truly the top edge of the phone (modulo safe-area auto-adjust).
        let effectiveTopInset: CGFloat = (zoomLevel == 4) ? 0 : topInset
        let effectiveBottomInset: CGFloat = (zoomLevel == 4) ? 0 : bottomInset
        scrollView.contentInset = UIEdgeInsets(top: effectiveTopInset, left: 0, bottom: effectiveBottomInset, right: 0)
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: effectiveTopInset, left: 0, bottom: effectiveBottomInset, right: 0)
        refreshCatFooterVisibility()

        // Text scale change → blow out every row's height cache and
        // propagate the new scale into each hosted SwiftUI tree.
        let textScaleChanged = abs(lastTextScale - textScale) > 0.001
        if textScaleChanged {
            lastTextScale = textScale
            for container in containers.values {
                container.invalidateNaturalHeight()
            }
        }

        // Diff — remove obsolete rows.
        let newIds = sessions.map(\.key)
        let newSet = Set(newIds)
        for key in Array(containers.keys) where !newSet.contains(key) {
            if let c = containers.removeValue(forKey: key) {
                c.cancelSwipeIfNeeded()
                c.removeFromSuperview()
            }
        }
        // Add new rows.
        for session in sessions where containers[session.key] == nil {
            let container = HomeRowContainer(scrollHost: self)
            containers[session.key] = container
            contentView.addSubview(container)
        }
        self.order = newIds

        // Push data into each row. During a pinch, display at zoom=4 so
        // every content layer is present and UIKit frame-clipping can
        // reveal it progressively. When idle, render at the committed
        // integer zoom.
        let displayZoom = isPinching ? 4 : zoomLevel
        for session in sessions {
            guard let container = containers[session.key] else { continue }
            let hid = "\(session.key.serverId)/\(session.key.threadId)"
            let pinned = pinnedThreadKeys.contains(SavedThreadsStore.PinnedKey(threadKey: session.key))
            container.configure(
                session: session,
                isOpening: openingKey == session.key,
                isHydrating: hydratingKeys.contains(hid),
                isCancelling: cancellingKeys.contains(hid),
                pinned: pinned,
                displayZoom: displayZoom,
                textScale: textScale,
                themeManager: themeManager,
                wallpaperManager: wallpaperManager,
                callbacks: callbacks
            )
        }

        let layoutAnimated = zoomChanged || textScaleChanged
        relayout(animated: layoutAnimated)
        updatePageBackgroundVisibility()

        // Repair stuck pinch-blur state. iOS can finish our paused
        // `UIViewPropertyAnimator` during NavigationStack push/pop
        // (terminal → back), leaving a row's `UIVisualEffectView`
        // showing the full end-state blur. SwiftUI re-runs `apply()`
        // after the pop, so this is the earliest reliable point to
        // reset the animator on every visible row.
        if !isPinching {
            for container in containers.values {
                container.forceResetPinchBlurIfIdle()
            }
        }

        // Just landed on the page-fit zoom from a different one — bring
        // the scroll position to the nearest page boundary so the user
        // doesn't end up resting between two cards. Done after relayout
        // so we snap against the freshly-sized rows.
        if enteredPageFit {
            snapToNearestPage(animated: layoutAnimated)
        }
    }

    /// Move `contentOffset` to the closest page boundary. Used when
    /// zooming into the page-fit zoom (4) and after layout shifts that
    /// would otherwise leave the user between cards.
    private func snapToNearestPage(animated: Bool) {
        let page = pageFitHeight()
        guard page > 0 else { return }
        let insetTop = scrollView.adjustedContentInset.top
        let pageOriginInScroll = -insetTop
        let relative = scrollView.contentOffset.y - pageOriginInScroll
        let nearestPage = (relative / page).rounded()
        let snapped = pageOriginInScroll + nearestPage * page
        let maxY = max(
            pageOriginInScroll,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let target = min(maxY, max(pageOriginInScroll, snapped))
        // Only animate if we're actually moving — otherwise the no-op
        // animation can introduce a one-frame offset glitch.
        if abs(target - scrollView.contentOffset.y) > 0.5 {
            scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
        }
    }

    // MARK: - Layout

    private func relayout(animated: Bool) {
        let width = bounds.width
        guard width > 0 else { return }

        let z = continuousZoom
        var y: CGFloat = 0
        var frames: [(HomeRowContainer, CGRect)] = []
        for key in order {
            guard let container = containers[key] else { continue }
            let h = rowHeight(for: container, at: z, width: width)
            frames.append((container, CGRect(x: 0, y: y, width: width, height: h)))
            y += h
        }
        let footerFrame: CGRect
        if shouldShowCatFooter {
            let h = catFooterHeight(width: width)
            footerFrame = CGRect(x: 0, y: y, width: width, height: h)
            y += h
        } else {
            footerFrame = .zero
        }
        let newContentSize = CGSize(width: width, height: y)

        if animated {
            UIView.animate(withDuration: zoomSnapDuration, delay: 0, options: [.curveEaseOut]) {
                for (container, frame) in frames { container.frame = frame }
                self.catFooterHostingController.view.frame = footerFrame
                self.contentView.frame = CGRect(origin: .zero, size: newContentSize)
                self.scrollView.contentSize = newContentSize
                self.updatePageBackgroundVisibility()
            } completion: { _ in
                self.updatePageBackgroundVisibility()
            }
        } else {
            for (container, frame) in frames { container.frame = frame }
            catFooterHostingController.view.frame = footerFrame
            contentView.frame = CGRect(origin: .zero, size: newContentSize)
            scrollView.contentSize = newContentSize
            updatePageBackgroundVisibility()
        }
    }

    fileprivate func updatePageBackgroundVisibility() {
        let canShowPageBackground = zoomLevel == 4 && !isPinching
        let visibleRect = scrollView.convert(scrollView.bounds, to: contentView)
            .insetBy(dx: 0, dy: -1)
        for key in order {
            guard let container = containers[key] else { continue }
            let isVisible = canShowPageBackground && visibleRect.intersects(container.frame)
            container.setPageBackgroundVisible(isVisible)
        }
    }

    private var shouldShowCatFooter: Bool {
        catFooterCountEligible && zoomLevel == 1 && !isPinching
    }

    private func catFooterHeight(width: CGFloat) -> CGFloat {
        let videoWidth = min(max(0, width - 48), 340)
        return videoWidth * 9.0 / 16.0 + 32
    }

    private func refreshCatFooterVisibility() {
        let visible = shouldShowCatFooter
        guard catFooterHostVisible != visible else { return }
        catFooterHostVisible = visible
        if visible {
            let playEntrance = !catFooterEntranceStarted
            catFooterEntranceStarted = true
            catFooterHostingController.rootView = AnyView(HomeCatFooterView(playEntrance: playEntrance))
        } else {
            catFooterHostingController.rootView = AnyView(EmptyView())
        }
        catFooterHostingController.view.isHidden = !visible
    }

    private func rowHeight(
        for container: HomeRowContainer,
        at zoom: Double,
        width: CGFloat
    ) -> CGFloat {
        // Four committed zoom levels: 1 SCAN, 2 GLANCE, 3 READ, 4 DEEP.
        // Continuous pinch interpolates linearly between adjacent anchors.
        let zc = max(1.0, min(4.0, zoom))
        // Zoom 4 (committed, not mid-pinch) is page-fit: every card is
        // exactly one visible-area tall so only one shows at a time and
        // the scroll view snaps to integer page boundaries — TikTok-style.
        // During a pinch, we still interpolate via the natural h4 so the
        // user can see content size grow continuously.
        if zc >= 4.0 && !isPinching {
            return pageFitHeight()
        }
        let h1 = heightAnchor(for: container, zoomInt: 1, width: width)
        let h2 = heightAnchor(for: container, zoomInt: 2, width: width)
        let h3 = heightAnchor(for: container, zoomInt: 3, width: width)
        let h4 = heightAnchor(for: container, zoomInt: 4, width: width)
        if zc <= 1.0 { return h1 }
        if zc <= 2.0 {
            let t = CGFloat(zc - 1.0)
            return h1 + t * (h2 - h1)
        }
        if zc <= 3.0 {
            let t = CGFloat(zc - 2.0)
            return h2 + t * (h3 - h2)
        }
        if zc >= 4.0 { return h4 }
        let t = CGFloat(zc - 3.0)
        return h3 + t * (h4 - h3)
    }

    /// Page-fit card height at zoom 4. Each card frame is exactly the
    /// full scroll-view bounds — that way card N's frame in scroll
    /// content runs `[N · boundsH, (N+1) · boundsH]` with no carved-out
    /// inset zones. The card's *internal* layout (`HomeRowContainer`)
    /// then offsets its host view by `topInsetValue` and stops it short
    /// of the bottom by `safeAreaInsets.top` so the chrome zones at the
    /// top of the *next* page (and the safe-area zone at the bottom of
    /// the *previous* page) draw empty container space rather than a
    /// neighbour's content.
    private func pageFitHeight() -> CGFloat {
        max(120, bounds.height)
    }

    private func heightAnchor(
        for container: HomeRowContainer,
        zoomInt: Int,
        width: CGFloat
    ) -> CGFloat {
        if let measured = container.cachedNaturalHeight(atZoom: zoomInt, width: width) {
            return measured
        }
        if container.currentDisplayZoom == zoomInt {
            return container.forceMeasureHostHeight(width: width)
        }
        switch zoomInt {
        case 1: return ZoomHeights.z1
        case 2: return ZoomHeights.z2
        case 3: return ZoomHeights.z3
        default: return container.naturalHeightAtZoom4(width: width)
        }
    }

    // MARK: - Pinch

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            beginPinch(g)
        case .changed:
            updatePinch(g)
        case .ended, .cancelled, .failed:
            endPinch(g)
        default:
            break
        }
    }

    private func beginPinch(_ g: UIPinchGestureRecognizer) {
        // Cancel any in-flight snap animation from a previous pinch so the
        // new pinch starts from a clean state.
        layer.removeAllAnimations()
        for key in order {
            containers[key]?.layer.removeAllAnimations()
        }
        pinchVignette.layer.removeAllAnimations()

        // Promote every row to displayZoom=4 FIRST so the full content tree
        // is rendered. UIKit frame animation reveals it progressively.
        // Also reset the per-row blur-progress peak so the ease-out curve
        // starts from zero for this new gesture.
        for key in order {
            containers[key]?.setDisplayZoom(4)
            containers[key]?.resetPinchBlurPeak()
        }

        isPinching = true
        refreshCatFooterVisibility()
        updateScrollEnabled()
        pinchStartZoom = continuousZoom
        pinchStartScale = g.scale

        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.pinchVignette.alpha = 1
        }

        // Anchor: the row containing the midpoint between the two
        // fingers. Capture the exact fractional position of the finger
        // within the row — this is the "tracking" anchor used at the
        // start of the gesture. As zoom climbs toward 4, the anchor
        // migrates from (rowIdx, frac) under the fingers to (rowIdx, 0)
        // at the top of the visible area, so the row naturally "opens
        // up" and its title lands at the top at max zoom.
        let anchorPoint = midpoint(of: g, in: self)
        pinchStartMidpoint = anchorPoint
        lastPinchMidpoint = anchorPoint
        let anchorContentY = scrollView.contentOffset.y + anchorPoint.y
        if let (idx, frac) = locateAnchor(atContentY: anchorContentY) {
            pinchAnchorIdx = idx
            pinchAnchorFraction = frac
        } else {
            pinchAnchorIdx = 0
            pinchAnchorFraction = 0
        }

        // Highlight the anchor row so the user sees which one the pinch
        // is operating on the instant their two fingers land. The
        // subsequent `updatePinch` calls drive the alpha down toward
        // zero as zoom progress increases, so the highlight "uses up"
        // as the row opens.
        if pinchAnchorIdx >= 0, pinchAnchorIdx < order.count {
            let key = order[pinchAnchorIdx]
            containers[key]?.setPinchHighlightAlpha(1, animated: true)
        }
    }

    private func updatePinch(_ g: UIPinchGestureRecognizer) {
        // Log-based pinch: delta in zoom levels = log2(current / start)
        // × sensitivity. Symmetric: halving the finger distance (scale
        // → 0.5) subtracts the same number of levels that doubling it
        // adds.
        let scaleRatio = max(0.05, Double(g.scale / pinchStartScale))
        let delta = log2(scaleRatio) * zoomLevelsPerOctave
        let zc = max(1.0, min(4.0, pinchStartZoom + delta))
        continuousZoom = zc

        relayout(animated: false)

        // Anchor stays pinned to the pinch-start finger midpoint —
        // not the current midpoint — so incidental finger drift
        // during the pinch doesn't shift the content around like a
        // scroll. The row expands and contracts in place under the
        // starting position of the gesture.
        if g.numberOfTouches >= 2 {
            lastPinchMidpoint = midpoint(of: g, in: self)
            if let newAnchorY = contentYForAnchor(
                idx: pinchAnchorIdx, fraction: pinchAnchorFraction
            ) {
                let raw = newAnchorY - pinchStartMidpoint.y
                scrollView.contentOffset = CGPoint(
                    x: scrollView.contentOffset.x,
                    y: raw
                )
            }
        }

        // Haptic tick on crossing the snap midpoints (1.5 and 3.0).
        let newInteger = snapZoom(zc)
        if newInteger != lastCommittedInteger {
            lastCommittedInteger = newInteger
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred(intensity: 0.5)
        }

        // Fade the anchor highlight inversely with zoom progress:
        // full alpha at pinchStartZoom, zero at z=4, reversing if the
        // user pinches back toward the start. Siblings get a blur
        // overlay that ramps up in the opposite direction so they
        // recede behind the opening row.
        let denom = max(0.001, 4.0 - pinchStartZoom)
        let progress = CGFloat(max(0, min(1, (zc - pinchStartZoom) / denom)))
        for (i, key) in order.enumerated() {
            guard let container = containers[key] else { continue }
            if i == pinchAnchorIdx {
                container.setPinchHighlightAlpha(1 - progress)
                container.setPinchBlurProgress(0)
            } else {
                container.setPinchHighlightAlpha(0)
                container.setPinchBlurProgress(progress)
            }
        }
    }

    /// Snap a continuous zoom into the three committed levels: {1, 2, 4}.
    /// Thresholds are the midpoints between levels.
    private func snapZoom(_ zc: Double) -> Int {
        if zc < 1.5 { return 1 }
        if zc < 3.0 { return 2 }
        return 4
    }

    private func endPinch(_ g: UIPinchGestureRecognizer) {
        let snapped = snapZoom(continuousZoom)
        let changed = snapped != zoomLevel
        zoomLevel = snapped
        continuousZoom = Double(snapped)

        // Finger midpoint for the drop anchor. UIKit usually removes
        // the touches before `.ended` fires, so we use the last
        // midpoint observed in `.changed` — otherwise the snap would
        // relayout row heights without compensating contentOffset and
        // the anchor row would visibly drift away on release.
        let dropFinger = lastPinchMidpoint

        // Spring-animate frames + contentSize + contentOffset together so
        // the snap feels like a single elastic motion instead of a linear
        // ease-out. SwiftUI stays at displayZoom=4 during the animation
        // so the content we're collapsing *to* is still fully rendered.
        UIView.animate(
            withDuration: 0.38, delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0.3,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.relayout(animated: false)
            if let newAnchorY = self.contentYForAnchor(
                idx: self.pinchAnchorIdx,
                fraction: self.pinchAnchorFraction
               ) {
                var raw = newAnchorY - dropFinger.y
                if let rowTopY = self.contentYForAnchor(idx: self.pinchAnchorIdx, fraction: 0) {
                    let maxOffsetForRowTopAtViewTop = rowTopY - self.scrollView.adjustedContentInset.top
                    raw = min(raw, maxOffsetForRowTopAtViewTop)
                }
                let maxY = max(-self.scrollView.adjustedContentInset.top,
                               self.scrollView.contentSize.height - self.scrollView.bounds.height + self.scrollView.adjustedContentInset.bottom)
                let minY = -self.scrollView.adjustedContentInset.top
                self.scrollView.contentOffset = CGPoint(
                    x: self.scrollView.contentOffset.x,
                    y: min(max(raw, minY), maxY)
                )
            }
        } completion: { _ in
            self.isPinching = false
            self.refreshCatFooterVisibility()
            self.updateScrollEnabled()
            // Reset displayZoom to the committed integer so each row
            // goes back to its gated-content rendering.
            for key in self.order {
                self.containers[key]?.setDisplayZoom(snapped)
            }
            // One more layout pass — the displayZoom=4 layouts may have
            // left the rows with slightly taller natural sizes than
            // needed at the snapped zoom.
            self.relayout(animated: false)
            self.updatePageBackgroundVisibility()
        }

        // Vignette + anchor highlight fade out together — slightly
        // faster than the snap so they're gone by the time the rows
        // settle.
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.pinchVignette.alpha = 0
        }
        for (i, key) in order.enumerated() {
            guard let container = containers[key] else { continue }
            if i == pinchAnchorIdx {
                container.setPinchHighlightAlpha(0, animated: true)
            } else {
                container.fadeOutPinchBlur()
            }
        }

        if changed {
            zoomCommit?(snapped)
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.impactOccurred()
        }
    }

    // MARK: - Anchor helpers

    private func midpoint(of g: UIPinchGestureRecognizer, in view: UIView) -> CGPoint {
        if g.numberOfTouches >= 2 {
            let p0 = g.location(ofTouch: 0, in: view)
            let p1 = g.location(ofTouch: 1, in: view)
            return CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        }
        return g.location(in: view)
    }

    private func locateAnchor(atContentY y: CGFloat) -> (Int, CGFloat)? {
        var cy: CGFloat = 0
        var lastValidIdx: Int? = nil
        for (i, key) in order.enumerated() {
            guard let container = containers[key] else { continue }
            let h = container.frame.height
            if h <= 0 { continue }
            if y >= cy && y <= cy + h {
                let frac = max(0, min(1, (y - cy) / h))
                return (i, frac)
            }
            cy += h
            lastValidIdx = i
        }
        // Past the last row → clamp to the LAST row (not the first).
        // Keeps the anchor on the row the user meant to pinch when
        // their midpoint lands in the empty space below the content.
        if let lastValidIdx, y > 0 {
            return (lastValidIdx, 1.0)
        }
        return nil
    }

    private func contentYForAnchor(idx: Int, fraction: CGFloat) -> CGFloat? {
        guard idx >= 0, idx < order.count else { return nil }
        var cy: CGFloat = 0
        for (i, key) in order.enumerated() {
            guard let container = containers[key] else { continue }
            let h = container.frame.height
            if i == idx { return cy + fraction * h }
            cy += h
        }
        return nil
    }
}

extension HomeSessionsScrollUIView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - UIScrollViewDelegate (page snap at zoom 4)
//
// Stock `UIScrollView.isPagingEnabled` pages at `bounds.height`, which
// ignores `contentInset.top`/`bottom`. Our scroll view ducks below the
// dynamic island via a top inset, so paging on raw bounds would drop
// each card half-under the island. Instead we retarget the deceleration
// destination ourselves: round to the nearest integer "page" (each one
// `pageFitHeight()` tall), measured in `contentInset.top`-anchored
// coordinates, then translate back to the raw `contentOffset.y` the
// scroll view will animate to.
extension HomeSessionsScrollUIView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updatePageBackgroundVisibility()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard zoomLevel == 4, !isPinching else { return }
        let page = pageFitHeight()
        guard page > 0 else { return }

        let insetTop = scrollView.adjustedContentInset.top
        let pageOriginInScroll = -insetTop  // contentOffset.y when first card is on screen

        // TikTok-style snap: velocity *direction* picks the next page,
        // not the proposed target distance. With `.fast` deceleration, a
        // hard flick covers a short distance — the system's
        // `targetContentOffset` can land in the first half of the next
        // page, which a nearest-rounding snap then pulls back to the
        // current page. The user reads that as "the flick didn't take".
        //
        // Instead: figure out which page the user is leaving (the one
        // they were resting on at drag start, ≈ floor of current offset
        // relative to page), then advance ±1 page based on velocity sign.
        // A truly slow lift (no flick) falls through to nearest-rounding
        // so it still snaps to whichever page is closer.
        let currentRelative = scrollView.contentOffset.y - pageOriginInScroll
        let lowerPage = floor(currentRelative / page)
        let upperPage = lowerPage + 1

        let velocityThreshold: CGFloat = 0.1
        let targetPage: CGFloat
        if velocity.y > velocityThreshold {
            targetPage = upperPage
        } else if velocity.y < -velocityThreshold {
            targetPage = lowerPage
        } else {
            // No real flick — snap to whichever side they're closer to.
            targetPage = (currentRelative / page).rounded()
        }

        let snapped = pageOriginInScroll + targetPage * page
        let maxY = max(pageOriginInScroll, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let minY = pageOriginInScroll
        targetContentOffset.pointee.y = min(maxY, max(minY, snapped))
    }

    /// Cover the case where the user drags slowly and lifts without
    /// triggering deceleration — `willEndDragging` doesn't redirect that
    /// path. Without this, a careful drag rests between cards.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        guard zoomLevel == 4, !isPinching else { return }
        snapToNearestPage(animated: true)
    }

    /// Belt-and-braces: if any path leaves us at a non-page offset
    /// after deceleration finishes, snap once more.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard zoomLevel == 4, !isPinching else { return }
        let page = pageFitHeight()
        guard page > 0 else { return }
        let insetTop = scrollView.adjustedContentInset.top
        let relative = scrollView.contentOffset.y - (-insetTop)
        let drift = abs(relative.truncatingRemainder(dividingBy: page))
        // Within 0.5pt of an exact page boundary → already aligned.
        if drift > 0.5 && drift < (page - 0.5) {
            snapToNearestPage(animated: true)
        }
    }
}

private struct HomeCatFooterView: View {
    let playEntrance: Bool

    @State private var showingLoop: Bool

    private let entranceURL = Bundle.main.url(forResource: "home_cat_entrance", withExtension: "webp")
    private let loopURL = Bundle.main.url(forResource: "home_cat", withExtension: "webp")

    init(playEntrance: Bool) {
        self.playEntrance = playEntrance
        self._showingLoop = State(initialValue: !playEntrance)
    }

    var body: some View {
        GeometryReader { proxy in
            if let imageURL = showingLoop ? loopURL : (entranceURL ?? loopURL) {
                let width = min(max(0, proxy.size.width - 48), 340)
                VStack {
                    CatTransmissionPressView {
                        AlphaAnimatedImageView(
                            fileURL: imageURL,
                            repeatCount: showingLoop ? 0 : 1,
                            onFinished: showingLoop ? nil : {
                                showingLoop = true
                            }
                        )
                    }
                        .frame(width: width, height: width * 9.0 / 16.0)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }
}

struct AlphaAnimatedImageView: UIViewRepresentable {
    let fileURL: URL
    var repeatCount: Int = 0
    var onFinished: (() -> Void)?

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.backgroundColor = .clear
        imageView.isOpaque = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = false
        context.coordinator.configure(
            imageView,
            fileURL: fileURL,
            repeatCount: repeatCount,
            onFinished: onFinished
        )
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        context.coordinator.configure(
            imageView,
            fileURL: fileURL,
            repeatCount: repeatCount,
            onFinished: onFinished
        )
    }

    static func dismantleUIView(_ imageView: UIImageView, coordinator: Coordinator) {
        coordinator.stop()
        imageView.image = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, CAAnimationDelegate {
        private var configuredURL: URL?
        private var configuredRepeatCount: Int?
        private var onFinished: (() -> Void)?
        private weak var imageView: UIImageView?
        private var finishedFired = false

        // Frames are swapped via `CAKeyframeAnimation` on
        // `layer.contents` in `.discrete` mode. Core Animation runs
        // this on the render server with its own high-precision
        // clock, so frame transitions land exactly at the encoded
        // per-frame delays — no main-thread/display-link aliasing,
        // and no flat tempo from UIImageView's animationImages.
        private static let animationKey = "alphaFrames"

        func configure(
            _ imageView: UIImageView,
            fileURL: URL,
            repeatCount: Int,
            onFinished: (() -> Void)?
        ) {
            self.onFinished = onFinished
            self.imageView = imageView
            guard configuredURL != fileURL || configuredRepeatCount != repeatCount else { return }
            configuredURL = fileURL
            configuredRepeatCount = repeatCount
            finishedFired = false

            imageView.animationImages = nil
            imageView.stopAnimating()
            imageView.layer.removeAnimation(forKey: Coordinator.animationKey)

            let animation = AlphaAnimatedImageView.animation(from: fileURL)
            guard let first = animation.frames.first else {
                imageView.image = nil
                return
            }
            // Seeding `image` first sizes the layer (via UIImageView's
            // intrinsicContentSize/contentMode) and ensures
            // `layer.contents` has a sane fallback before/after the
            // animation runs.
            imageView.image = UIImage(cgImage: first)

            guard animation.frames.count > 1, animation.duration > 0 else {
                if repeatCount > 0, !finishedFired {
                    finishedFired = true
                    onFinished?()
                }
                return
            }

            let keyAnim = CAKeyframeAnimation(keyPath: "contents")
            keyAnim.values = animation.frames.map { $0 as Any }
            // Discrete mode wants one more keyTime than values:
            // values[i] is held over [keyTimes[i], keyTimes[i+1]).
            var keyTimes: [NSNumber] = [0.0]
            for end in animation.frameEndTimes {
                keyTimes.append(NSNumber(value: end / animation.duration))
            }
            keyAnim.keyTimes = keyTimes
            keyAnim.duration = animation.duration
            keyAnim.repeatCount = repeatCount > 0 ? Float(repeatCount) : .infinity
            keyAnim.calculationMode = .discrete
            keyAnim.fillMode = .forwards
            keyAnim.isRemovedOnCompletion = false
            keyAnim.delegate = self

            imageView.layer.add(keyAnim, forKey: Coordinator.animationKey)
        }

        func stop() {
            imageView?.layer.removeAnimation(forKey: Coordinator.animationKey)
        }

        func animationDidStop(_ anim: CAAnimation, finished: Bool) {
            guard finished, !finishedFired else { return }
            guard let repeats = configuredRepeatCount, repeats > 0 else { return }
            finishedFired = true
            onFinished?()
        }
    }

    private struct Animation {
        let frames: [CGImage]
        /// Cumulative end-time for each frame (frameEndTimes[i] is the
        /// timestamp at which frame i finishes / frame i+1 begins).
        let frameEndTimes: [TimeInterval]
        let duration: TimeInterval
    }

    /// Our iOS APNGs were authored at 10fps (100ms per frame), but the
    /// equivalent Android WebPs render at 15fps (67ms per frame) — so
    /// the same 165-frame entrance runs 16.5s on iOS vs 11.055s on
    /// Android. Force playback at the Android cadence by overriding
    /// the encoded delays. The source frames are uniform in both
    /// files, so a flat per-frame duration here is exact, not a
    /// resampling approximation.
    private static let playbackFrameDuration: TimeInterval = 1.0 / 15.0

    private static func animation(from url: URL) -> Animation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return Animation(frames: [], frameEndTimes: [], duration: 0)
        }
        let count = CGImageSourceGetCount(source)
        var frames: [CGImage] = []
        var ends: [TimeInterval] = []
        frames.reserveCapacity(count)
        ends.reserveCapacity(count)
        var cumulative: TimeInterval = 0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(cgImage)
            cumulative += playbackFrameDuration
            ends.append(cumulative)
        }
        return Animation(
            frames: frames,
            frameEndTimes: ends,
            duration: max(cumulative, 0.1)
        )
    }

}

// MARK: - Row container

final class HomeRowContainer: UIView {
    private let hostingController: UIHostingController<AnyView>
    private let backgroundHostingController: UIHostingController<AnyView>
    /// Clipping window for the hosted SwiftUI view. At zoom 4 the
    /// SwiftUI content can be naturally taller than the available
    /// screen-fit space (long response previews). The hosting view's
    /// own `.clipsToBounds` doesn't help, because UIHostingController
    /// sizes its `view` to the SwiftUI body's intrinsic height — so
    /// the view itself grows. Putting it inside this fixed-height
    /// clipping container is what actually keeps the title pinned at
    /// the top while the bottom of the content gets cut off.
    private let hostClip = UIView()
    private let actionsBackground = UIView()
    private let pinchHighlight = UIView()
    private let pinchBlur = UIVisualEffectView(effect: nil)
    /// Paused animator that scrubs the blur effect's intensity via
    /// `fractionComplete`. Direct alpha on a `UIVisualEffectView`
    /// gives a crossfade rather than a progressive blur — scrubbing
    /// an animator's fractionComplete is the canonical way to
    /// interpolate blur radius on iOS.
    private var pinchBlurAnimator: UIViewPropertyAnimator?
    private func makePinchBlurAnimator() -> UIViewPropertyAnimator {
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear)
        animator.addAnimations { [weak self] in
            self?.pinchBlur.effect = UIBlurEffect(style: .systemThinMaterialDark)
        }
        animator.pausesOnCompletion = true
        // IMPORTANT: the animator must be `.active` (running or paused)
        // for `fractionComplete` scrubbing to take effect. Right after
        // construction the animator is `.inactive` and scrubs silently
        // do nothing — so we kick it to running, immediately pause,
        // and seed the progress at 0.
        animator.startAnimation()
        animator.pauseAnimation()
        animator.fractionComplete = 0
        return animator
    }
    private let leadingIconView = UIImageView()
    private let trailingIconView = UIImageView()

    private var session: HomeDashboardRecentSession?
    private var isOpening = false
    private var isHydrating = false
    private var isCancelling = false
    private var pinned = false
    private(set) var currentDisplayZoom: Int = 2
    private var displayZoom: Int {
        get { currentDisplayZoom }
        set { currentDisplayZoom = newValue }
    }
    private var callbacks: HomeSessionsScrollView.Callbacks?
    private var cachedNaturalHeight: CGFloat?
    private var cachedMeasureWidth: CGFloat = 0
    private var textScale: CGFloat = 1.0
    private var themeManager: ThemeManager?
    private var wallpaperManager: WallpaperManager?
    private var pageBackgroundVisible = false
    private var fadeLink: CADisplayLink?
    /// Natural hostingView height per displayZoom, keyed by (zoom,width).
    /// Invalidated when session data or displayZoom changes.
    private var hostHeightByZoom: [Int: CGFloat] = [:]
    private var hostHeightCachedWidth: CGFloat = 0

    private var offsetX: CGFloat = 0
    private var activated: Bool = false
    private var pastThreshold: Bool = false
    private var swipeStartPoint: CGPoint = .zero
    private var swipeTracking: Bool = false

    private static let fullSwipeThreshold: CGFloat = 120
    private static let activationDistance: CGFloat = 24
    private static let horizontalDominance: CGFloat = 2.0

    private weak var scrollHost: HomeSessionsScrollUIView?

    private lazy var swipeRecognizer: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        g.minimumPressDuration = 0
        g.allowableMovement = .greatestFiniteMagnitude
        g.cancelsTouchesInView = false
        g.delegate = self
        return g
    }()

    init(scrollHost: HomeSessionsScrollUIView) {
        self.scrollHost = scrollHost
        self.hostingController = UIHostingController(rootView: AnyView(EmptyView()))
        self.backgroundHostingController = UIHostingController(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .clear

        backgroundHostingController.view.backgroundColor = .clear
        backgroundHostingController.view.isUserInteractionEnabled = false
        backgroundHostingController.view.isHidden = true
        addSubview(backgroundHostingController.view)

        // Actions background — tinted view that fills the row behind the
        // content, crossfading between leading (reply) / trailing (hide).
        actionsBackground.backgroundColor = .clear
        actionsBackground.alpha = 0
        addSubview(actionsBackground)

        leadingIconView.image = UIImage(systemName: "arrowshape.turn.up.left.fill")
        leadingIconView.tintColor = .white
        leadingIconView.contentMode = .center
        leadingIconView.alpha = 0
        actionsBackground.addSubview(leadingIconView)

        trailingIconView.image = UIImage(systemName: "eye.slash.fill")
        trailingIconView.tintColor = .white
        trailingIconView.contentMode = .center
        trailingIconView.alpha = 0
        actionsBackground.addSubview(trailingIconView)

        hostingController.view.backgroundColor = .clear
        hostClip.clipsToBounds = true
        hostClip.backgroundColor = .clear
        addSubview(hostClip)
        hostClip.addSubview(hostingController.view)

        // Pinch blur — non-anchor rows have their visual effect
        // interpolated via `pinchBlurAnimator.fractionComplete` during
        // pinch. Starts with `effect = nil` (no blur) and scrubs up
        // to a thin material blur as zoom progresses.
        //
        // Skipped whenever we render as a Mac app (Catalyst OR iOS-on-Mac):
        // UIBlurEffect bridges to NSVisualEffectView and does not honor a
        // paused animator at fractionComplete=0 — it renders the full
        // material instead of nothing, so the blur sits over every row
        // obscuring all content. No pinch gesture in Mac modes anyway,
        // so the whole pipeline is unused there.
        //
        // iOS Reduce Transparency has the same practical failure mode:
        // system material can collapse to an opaque fallback over the
        // hosted SwiftUI row. In that accessibility mode, the contrast-
        // safe behavior is no blur overlay at all.
        pinchBlur.isUserInteractionEnabled = false
        pinchBlur.alpha = 1
        if !LitterPlatform.rendersAsMacApp {
            updatePinchBlurAvailability()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reduceTransparencyDidChange),
                name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                object: nil
            )
        }

        // Pinch highlight — subtle accent tint over the anchor row
        // while a pinch is live. Fades in on `.began`, tracks the
        // inverse of zoom progress during `.changed` (so it quietly
        // disappears as the row opens), and fades out on release.
        pinchHighlight.backgroundColor = UIColor(LitterTheme.accent).withAlphaComponent(0.14)
        pinchHighlight.layer.cornerRadius = 6
        pinchHighlight.isUserInteractionEnabled = false
        pinchHighlight.alpha = 0
        addSubview(pinchHighlight)

        addGestureRecognizer(swipeRecognizer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        cancelSwipeIfNeeded()
        // UIKit raises NSInternalInconsistencyException if a
        // UIViewPropertyAnimator is released while still in `.active`
        // (running or paused). We hold it paused-active for
        // `fractionComplete` scrubbing, so terminate it explicitly here.
        fadeLink?.invalidate()
        if !LitterPlatform.rendersAsMacApp {
            NotificationCenter.default.removeObserver(
                self,
                name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                object: nil
            )
            tearDownPinchBlurAnimator()
        }
    }

    @objc private func reduceTransparencyDidChange() {
        updatePinchBlurAvailability()
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelSwipeIfNeeded()
            return
        }
        // `pinchBlur`'s intensity is driven by a paused
        // `UIViewPropertyAnimator` whose `fractionComplete` is scrubbed
        // between `effect = nil` and `systemThinMaterialDark`. When the
        // hosting NavigationStack pushes a new screen (e.g. terminal)
        // and pops back, iOS can finish/invalidate paused property
        // animators, leaving the blur snapped to its full effect — a
        // milky band sits over the affected rows. When we re-attach to
        // a window with no pinch in progress, reset the animator from
        // scratch so it scrubs cleanly back to nil.
        guard !LitterPlatform.rendersAsMacApp,
              !UIAccessibility.isReduceTransparencyEnabled,
              scrollHost?.pinchActive != true
        else { return }
        fadeLink?.invalidate()
        fadeLink = nil
        tearDownPinchBlurAnimator()
        pinchBlur.effect = nil
        pinchBlurAnimator = makePinchBlurAnimator()
    }

    private func updatePinchBlurAvailability() {
        if UIAccessibility.isReduceTransparencyEnabled {
            pinchBlur.removeFromSuperview()
            pinchBlur.effect = nil
            tearDownPinchBlurAnimator()
            return
        }

        if pinchBlur.superview == nil {
            if pinchHighlight.superview === self {
                insertSubview(pinchBlur, belowSubview: pinchHighlight)
            } else {
                insertSubview(pinchBlur, aboveSubview: hostClip)
            }
        }

        if pinchBlurAnimator == nil {
            pinchBlurAnimator = makePinchBlurAnimator()
        }
    }

    private func tearDownPinchBlurAnimator() {
        guard let animator = pinchBlurAnimator else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .current)
        pinchBlurAnimator = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundHostingController.view.frame = bounds
        actionsBackground.frame = bounds
        pinchBlur.frame = bounds
        pinchHighlight.frame = bounds.insetBy(dx: 4, dy: 2)

        let iconSize: CGFloat = 22
        leadingIconView.frame = CGRect(
            x: 24, y: (bounds.height - iconSize) / 2,
            width: iconSize, height: iconSize
        )
        trailingIconView.frame = CGRect(
            x: bounds.width - 24 - iconSize, y: (bounds.height - iconSize) / 2,
            width: iconSize, height: iconSize
        )

        // Two-layer layout:
        //   * `hostClip` is the visible window — at zoom 4 it's the
        //     screen-fit rectangle (offset by the chrome height at top
        //     and stopped short by the safe-area top at the bottom);
        //     at lower zooms it equals the SwiftUI natural height.
        //   * `hostingController.view` sits at (0, 0) inside `hostClip`
        //     and is sized to the SwiftUI content's natural height.
        //     When natural > clipHeight (long response preview at z4),
        //     the hosting view extends below the clip's bottom and is
        //     cut off there. The title at (0, 0) of the hosting view
        //     stays pinned to the top of the clip — never pushed up.
        let width = bounds.width
        guard width > 0 else { return }
        if hostHeightCachedWidth != width {
            hostHeightByZoom.removeAll(keepingCapacity: true)
            hostHeightCachedWidth = width
        }
        let pageFit = displayZoom == 4 && (scrollHost?.isPinching == false)
        let topPad: CGFloat = pageFit ? (scrollHost?.topInsetValue ?? 0) : 0
        let safeAreaTop: CGFloat = pageFit ? (scrollHost?.scrollViewSafeAreaTop ?? 0) : 0
        let naturalHeight = hostHeightByZoom[displayZoom] ?? measureHostHeight(width: width)
        let clipHeight: CGFloat = if pageFit {
            max(0, bounds.height - topPad - safeAreaTop)
        } else {
            naturalHeight
        }
        hostClip.frame = CGRect(
            x: offsetX, y: topPad, width: width, height: clipHeight
        )
        hostingController.view.frame = CGRect(
            x: 0, y: 0, width: width, height: naturalHeight
        )
    }

    /// Public wrapper — called by the scroll host when it needs a
    /// measurement on demand (e.g., the first `relayout` after a row
    /// is configured, before any implicit layoutSubviews pass).
    @discardableResult
    func forceMeasureHostHeight(width: CGFloat) -> CGFloat {
        measureHostHeight(width: width)
    }

    /// Measure the hosted SwiftUI view's natural height at the current
    /// `displayZoom`. Caches the result so repeated layouts during a
    /// pinch don't re-measure. Must be called only after `rootView` has
    /// been set via `refreshRootView`.
    @discardableResult
    private func measureHostHeight(width: CGFloat) -> CGFloat {
        // Give the host a tall sizing frame so sizeThatFits reports the
        // true intrinsic, not a compressed version.
        hostingController.view.frame = CGRect(x: offsetX, y: 0, width: width, height: 10_000)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        let size = hostingController.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        let h = max(12, size.height)
        hostHeightByZoom[displayZoom] = h
        if displayZoom == 4 {
            cachedNaturalHeight = h
            cachedMeasureWidth = width
        }
        return h
    }

    // MARK: - Configure

    func configure(
        session: HomeDashboardRecentSession,
        isOpening: Bool,
        isHydrating: Bool,
        isCancelling: Bool,
        pinned: Bool,
        displayZoom: Int,
        textScale: CGFloat,
        themeManager: ThemeManager,
        wallpaperManager: WallpaperManager,
        callbacks: HomeSessionsScrollView.Callbacks
    ) {
        let sessionChanged = self.session != session
        if sessionChanged {
            cancelSwipeIfNeeded()
        }
        let stateChanged = self.isOpening != isOpening ||
            self.isHydrating != isHydrating ||
            self.isCancelling != isCancelling ||
            self.pinned != pinned
        let zoomChanged = self.displayZoom != displayZoom
        let textScaleChanged = abs(self.textScale - textScale) > 0.001
        let environmentChanged = self.themeManager !== themeManager ||
            self.wallpaperManager !== wallpaperManager
        self.session = session
        self.isOpening = isOpening
        self.isHydrating = isHydrating
        self.isCancelling = isCancelling
        self.pinned = pinned
        self.displayZoom = displayZoom
        self.textScale = textScale
        self.themeManager = themeManager
        self.wallpaperManager = wallpaperManager
        self.callbacks = callbacks

        if sessionChanged || textScaleChanged {
            cachedNaturalHeight = nil
            hostHeightByZoom.removeAll(keepingCapacity: true)
        }
        if sessionChanged || stateChanged || zoomChanged || textScaleChanged {
            refreshRootView()
            setNeedsLayout()
        }
        if sessionChanged || zoomChanged || environmentChanged {
            refreshPageBackgroundView()
        }
    }

    /// Drive blur intensity via the paused animator's fractionComplete.
    /// Non-anchor rows track pinch progress; anchor row stays at 0.
    ///
    /// Shape:
    ///   * pow-curve eases the start (progress^1.8) so slight pinches
    ///     don't slam straight into heavy blur.
    ///   * multiplied by `pinchBlurCeiling` so even at full zoom the
    ///     blur tops out below the animator's max — keeps siblings
    ///     legible as silhouettes instead of milky squares.
    private static let pinchBlurCeiling: CGFloat = 0.5
    private static let pinchBlurExponent: CGFloat = 2.8
    func setPinchBlurProgress(_ progress: CGFloat) {
        // Mac modes (Catalyst + iOS-on-Mac) don't install the
        // pinch-blur view (see init).
        if LitterPlatform.rendersAsMacApp { return }
        guard !UIAccessibility.isReduceTransparencyEnabled else {
            pinchBlur.removeFromSuperview()
            pinchBlur.effect = nil
            tearDownPinchBlurAnimator()
            return
        }
        updatePinchBlurAvailability()
        guard let pinchBlurAnimator else { return }
        let p = max(0, min(1, progress))
        // Symmetric ease-out curve: blur tracks zoom progress both
        // directions so a pinch-in that had slowly-building blur will
        // slowly release it on the way back. No peak tracking — it
        // introduced a fast-drop curve on collapse that felt like the
        // blur abruptly vanished.
        let eased = pow(p, Self.pinchBlurExponent) * Self.pinchBlurCeiling
        pinchBlurAnimator.fractionComplete = max(0, min(0.999, eased))
    }

    /// No-op kept for the scroll host's `.began` call site; the
    /// direction-aware curve was replaced with a symmetric one.
    func resetPinchBlurPeak() {}

    /// Force the pinch blur back to a clean, nil-effect state when no
    /// pinch is in progress. Called from the scroll host's `apply()`
    /// after every SwiftUI update — covers the case where iOS finishes
    /// our paused `UIViewPropertyAnimator` out from under us during a
    /// NavigationStack push/pop (e.g. into the terminal screen and
    /// back), which otherwise snaps the blur to its end state and
    /// leaves a milky band over the row.
    func forceResetPinchBlurIfIdle() {
        if LitterPlatform.rendersAsMacApp { return }
        if UIAccessibility.isReduceTransparencyEnabled { return }
        // A live fade-out is still scrubbing the animator's
        // fractionComplete back to 0 — don't yank the animator out
        // from under it.
        if fadeLink != nil { return }
        // If the scroll host says a pinch is active, the animator is
        // being scrubbed in real time. Leave it alone.
        if scrollHost?.pinchActive == true { return }
        tearDownPinchBlurAnimator()
        pinchBlur.effect = nil
        pinchBlurAnimator = makePinchBlurAnimator()
    }

    /// Smoothly wind the blur back to zero on pinch release. Uses
    /// a CADisplayLink-driven tween because UIViewPropertyAnimator's
    /// `fractionComplete` can't be animated with `UIView.animate`.
    func fadeOutPinchBlur(duration: TimeInterval = 0.25) {
        if LitterPlatform.rendersAsMacApp { return }
        guard !UIAccessibility.isReduceTransparencyEnabled,
              let pinchBlurAnimator else {
            fadeLink?.invalidate()
            fadeLink = nil
            pinchBlur.removeFromSuperview()
            pinchBlur.effect = nil
            return
        }
        fadeLink?.invalidate()
        let start = CFAbsoluteTimeGetCurrent()
        let from = pinchBlurAnimator.fractionComplete
        let link = CADisplayLink(target: PinchBlurFadeTarget { [weak self] in
            guard let self else { return }
            let t = min(1, (CFAbsoluteTimeGetCurrent() - start) / duration)
            let eased = 1 - (1 - t) * (1 - t)  // ease-out quad
            let value = from * (1 - CGFloat(eased))
            self.pinchBlurAnimator?.fractionComplete = max(0, value)
            if t >= 1 {
                self.fadeLink?.invalidate()
                self.fadeLink = nil
            }
        }, selector: #selector(PinchBlurFadeTarget.tick))
        link.add(to: .main, forMode: .common)
        fadeLink = link
    }

    /// Set the highlight opacity directly (0–1). Used during a live
    /// pinch so the tint fades in sync with zoom progress — strong at
    /// pinch start, invisible at full open, reversing on collapse.
    func setPinchHighlightAlpha(_ alpha: CGFloat, animated: Bool = false) {
        let clamped = max(0, min(1, alpha))
        if animated {
            UIView.animate(
                withDuration: clamped > pinchHighlight.alpha ? 0.12 : 0.22, delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                self.pinchHighlight.alpha = clamped
            }
        } else {
            pinchHighlight.alpha = clamped
        }
    }

    func setDisplayZoom(_ z: Int) {
        guard displayZoom != z else { return }
        displayZoom = z
        refreshRootView()
        refreshPageBackgroundView()
        // Re-measure host height for the new displayZoom (cached per zoom).
        setNeedsLayout()
        layoutIfNeeded()
    }

    func invalidateNaturalHeight() {
        cachedNaturalHeight = nil
        hostHeightByZoom.removeAll(keepingCapacity: true)
    }

    /// Report a cached natural height for a given zoom level, if one
    /// has been measured at the current width. `layoutSubviews` pops a
    /// measurement for whatever the current `displayZoom` is, so rows
    /// naturally populate this cache as the user browses at different
    /// committed zooms.
    func cachedNaturalHeight(atZoom zoom: Int, width: CGFloat) -> CGFloat? {
        guard hostHeightCachedWidth == width else { return nil }
        return hostHeightByZoom[zoom]
    }

    private func refreshRootView() {
        guard let session, let callbacks else { return }
        let sessionSnapshot = session
        let openTap: () -> Void = { [weak self] in
            guard let self, self.scrollHost?.pinchActive != true else { return }
            callbacks.onOpen(sessionSnapshot)
        }
        let content = HomeSessionRowContent(
            session: session,
            isOpening: isOpening,
            isHydrating: isHydrating,
            isCancelling: isCancelling,
            zoomLevel: displayZoom,
            pinned: pinned,
            onTap: openTap,
            onReply: { callbacks.onReply(sessionSnapshot) },
            onHide: { callbacks.onHide(sessionSnapshot.key) },
            onPin: { callbacks.onPin(sessionSnapshot.key) },
            onUnpin: { callbacks.onUnpin(sessionSnapshot.key) },
            onCancelTurn: { callbacks.onCancelTurn(sessionSnapshot) },
            onDelete: { callbacks.onDelete(sessionSnapshot) },
            onFork: { callbacks.onFork(sessionSnapshot) },
            onShowPiP: { callbacks.onShowPiP(sessionSnapshot) }
        )
        .environment(\.textScale, textScale)
        hostingController.rootView = AnyView(content)
    }

    func setPageBackgroundVisible(_ visible: Bool) {
        guard pageBackgroundVisible != visible else { return }
        pageBackgroundVisible = visible
        refreshPageBackgroundView()
    }

    private func refreshPageBackgroundView() {
        guard displayZoom == 4,
              pageBackgroundVisible,
              let session,
              let themeManager,
              let wallpaperManager else {
            backgroundHostingController.rootView = AnyView(EmptyView())
            backgroundHostingController.view.isHidden = true
            return
        }

        let background = ChatWallpaperBackground(threadKey: session.key)
            .environment(themeManager)
            .environment(wallpaperManager)
        backgroundHostingController.rootView = AnyView(background)
        backgroundHostingController.view.isHidden = false
    }

    // MARK: - Measurement

    /// Natural container height at zoom 4 — equals the hosted SwiftUI
    /// view's intrinsic height at displayZoom=4. Only reliable when
    /// the row is currently rendering at displayZoom=4 (set at pinch
    /// begin and at committed z=4).
    func naturalHeightAtZoom4(width: CGFloat) -> CGFloat {
        if let cached = cachedNaturalHeight, abs(cachedMeasureWidth - width) < 0.5 {
            return cached
        }
        guard session != nil else { return 400 }
        guard displayZoom == 4 else {
            return 400
        }
        // Invalidate any existing measurement for this zoom, then
        // remeasure with the current width. `measureHostHeight` caches
        // into `hostHeightByZoom` and `cachedNaturalHeight`.
        hostHeightByZoom.removeValue(forKey: 4)
        return measureHostHeight(width: width)
    }

    // MARK: - Swipe

    @objc private func handleSwipe(_ g: UILongPressGestureRecognizer) {
        guard let session, let callbacks else { return }

        // If a second finger lands (pinch or two-finger scroll elsewhere),
        // bail immediately — reset offset and stop tracking.
        if g.numberOfTouches > 1 || scrollHost?.pinchActive == true {
            if swipeTracking {
                cancelSwipeIfNeeded(animated: true)
            }
            return
        }

        let point = g.location(in: self)
        switch g.state {
        case .began:
            swipeStartPoint = point
            swipeTracking = true
        case .changed:
            guard swipeTracking else { return }
            let w = point.x - swipeStartPoint.x
            let h = point.y - swipeStartPoint.y
            if !activated {
                let horizontalDominant = abs(w) > abs(h) * Self.horizontalDominance
                let pastActivation = abs(w) >= Self.activationDistance
                if horizontalDominant && pastActivation {
                    activated = true
                    scrollHost?.noteRowSwipeChanged(activated: true)
                    let gen = UIImpactFeedbackGenerator(style: .light)
                    gen.impactOccurred(intensity: 0.5)
                } else {
                    return
                }
            }
            offsetX = w
            updateActionsVisuals()
            let nowPast = abs(w) >= Self.fullSwipeThreshold
            if nowPast != pastThreshold {
                pastThreshold = nowPast
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.impactOccurred(intensity: 0.7)
            }
            setNeedsLayout()
            layoutIfNeeded()
        case .ended, .cancelled, .failed:
            guard swipeTracking else { return }
            let w = point.x - swipeStartPoint.x
            let shouldFire = activated && scrollHost?.pinchActive != true
            cancelSwipeIfNeeded(animated: true)
            if shouldFire && w > Self.fullSwipeThreshold {
                callbacks.onReply(session)
                let gen = UIImpactFeedbackGenerator(style: .heavy)
                gen.impactOccurred(intensity: 0.9)
            } else if shouldFire && w < -Self.fullSwipeThreshold {
                callbacks.onHide(session.key)
                let gen = UIImpactFeedbackGenerator(style: .heavy)
                gen.impactOccurred(intensity: 0.9)
            }
        default:
            break
        }
    }

    /// A row can leave the hierarchy or have its session replaced while a
    /// horizontal swipe is committed. Make that cleanup idempotent so the
    /// scroll host's swipe count cannot outlive the row that incremented it.
    func cancelSwipeIfNeeded(animated: Bool = false) {
        let wasActivated = activated
        swipeTracking = false
        activated = false
        pastThreshold = false
        if wasActivated {
            scrollHost?.noteRowSwipeChanged(activated: false)
        }
        guard offsetX != 0 else { return }
        reset(animated: animated)
    }

    private func reset(animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: 0.35, delay: 0,
                usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                options: [.curveEaseOut]
            ) {
                self.offsetX = 0
                self.updateActionsVisuals()
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        } else {
            offsetX = 0
            updateActionsVisuals()
            setNeedsLayout()
        }
    }

    private func updateActionsVisuals() {
        let progress = min(1, abs(offsetX) / Self.fullSwipeThreshold)
        let tintAlpha = progress * 0.55
        let iconAlpha = progress
        let iconScale: CGFloat = 0.7 + 0.3 * progress

        if offsetX > 0 {
            actionsBackground.backgroundColor = UIColor(LitterTheme.accent)
            actionsBackground.alpha = tintAlpha
            leadingIconView.alpha = iconAlpha
            leadingIconView.transform = CGAffineTransform(scaleX: iconScale, y: iconScale)
            trailingIconView.alpha = 0
        } else if offsetX < 0 {
            actionsBackground.backgroundColor = UIColor(LitterTheme.danger)
            actionsBackground.alpha = tintAlpha
            trailingIconView.alpha = iconAlpha
            trailingIconView.transform = CGAffineTransform(scaleX: iconScale, y: iconScale)
            leadingIconView.alpha = 0
        } else {
            actionsBackground.alpha = 0
            leadingIconView.alpha = 0
            trailingIconView.alpha = 0
        }
    }
}

extension HomeRowContainer: UIGestureRecognizerDelegate {
    /// Run simultaneously with the enclosing scroll view's pan — our
    /// long-press recognizer observes touches without claiming direction,
    /// so scrolling continues to work until we latch onto a horizontal
    /// commitment in `handleSwipe`.
    func gestureRecognizer(
        _ g: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - SwiftUI row content

/// Hosts the session card (title + status indicator + per-zoom layers)
/// along with the `.contextMenu` and an `.onTapGesture`. This is the
/// SwiftUI view that each `HomeRowContainer` hosts inside its
/// `UIHostingController`. It is a pure function of its props — during a
/// pinch, UIKit sets `zoomLevel = 4` so the full content tree is
/// available for the outer frame to reveal; when idle, `zoomLevel` is
/// the committed integer.
struct HomeSessionRowContent: View {
    let session: HomeDashboardRecentSession
    let isOpening: Bool
    let isHydrating: Bool
    let isCancelling: Bool
    let zoomLevel: Int
    let pinned: Bool
    let onTap: () -> Void
    let onReply: () -> Void
    let onHide: () -> Void
    let onPin: () -> Void
    let onUnpin: () -> Void
    let onCancelTurn: () -> Void
    let onDelete: () -> Void
    let onFork: () -> Void
    let onShowPiP: () -> Void

    var body: some View {
        SessionCanvasLine(
            session: session,
            isOpening: isOpening,
            isHydrating: isHydrating,
            isCancelling: isCancelling,
            zoomLevel: zoomLevel
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu(menuItems: {
            Button { onReply() } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button { onFork() } label: {
                Label("Fork", systemImage: "arrow.triangle.branch")
            }
            .disabled(session.hasTurnActive)
            if session.hasTurnActive {
                Button(role: .destructive) { onCancelTurn() } label: {
                    Label("Cancel Turn", systemImage: "stop.circle")
                }
            }
            Button {
                if pinned { onUnpin() } else { onPin() }
            } label: {
                Label(
                    pinned ? "Remove from Home" : "Pin to Home",
                    systemImage: pinned ? "minus.circle" : "pin"
                )
            }
            if AVPictureInPictureController.isPictureInPictureSupported() {
                Button { onShowPiP() } label: {
                    Label("Show in Picture in Picture", systemImage: "pip")
                }
            }
            Button { onHide() } label: {
                Label("Hide from Home", systemImage: "eye.slash")
            }
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete Session", systemImage: "trash")
            }
        }, preview: {
            // Compact preview — without this, iOS renders the whole
            // hosted row (which is huge at zoom 4) as the context-menu
            // preview and it scales up into a "giant row" on screen.
            SessionContextMenuPreview(session: session)
        })
        .accessibilityIdentifier("home.recentSessionCard")
    }
}

/// Small card that previews a session in the context-menu popup.
/// Constrained width + brief content so the long-press preview stays
/// visually compact regardless of the current zoom level.
private struct SessionContextMenuPreview: View {
    let session: HomeDashboardRecentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.sessionTitle.isEmpty ? "Session" : session.sessionTitle)
                .litterFont(size: LitterFont.conversationBodyPointSize, weight: .medium)
                .foregroundStyle(LitterTheme.textPrimary)
                .lineLimit(2)
            if !session.serverDisplayName.isEmpty {
                HStack(spacing: 5) {
                    Text(session.agentRuntimeKind.displayLabel)
                        .litterFont(size: 9, weight: .semibold)
                        .foregroundStyle(LitterTheme.accent.opacity(0.8))
                    Text(session.serverDisplayName)
                        .litterFont(size: 10)
                        .foregroundStyle(LitterTheme.textSecondary.opacity(0.75))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 240, alignment: .leading)
        .background(LitterTheme.surface)
    }
}
