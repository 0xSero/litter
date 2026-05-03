import SwiftUI

enum CoachmarkTarget: Hashable {
    case addServer
    case newThread
    case search
    case voice
}

struct CoachmarkAnchorKey: PreferenceKey {
    static var defaultValue: [CoachmarkTarget: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [CoachmarkTarget: Anchor<CGRect>],
        nextValue: () -> [CoachmarkTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func coachmarkAnchor(_ target: CoachmarkTarget) -> some View {
        anchorPreference(key: CoachmarkAnchorKey.self, value: .bounds) { anchor in
            [target: anchor]
        }
    }
}

struct OnboardingCoachmarksView: View {
    let anchors: [CoachmarkTarget: Anchor<CGRect>]

    @Environment(\.colorScheme) private var colorScheme

    enum LineStyle {
        case smoothCurve        // straight quadratic curve, no wiggle
        case solidSquiggle      // continuous sine wave
        case dashedSquiggle     // dashed sine wave
        case dotted             // round dot pattern
    }

    private struct Item: Identifiable {
        let id: CoachmarkTarget
        let primary: String
        let secondary: String?
        /// Label center as a fraction of the container size (0..1 in each
        /// axis). The bottom three labels sit close to their target buttons
        /// so the arrows are short; addServer sits below the pill with
        /// enough vertical gap that the arrow's curve is visible.
        let position: UnitPoint
        /// Fixed render width used both for layout and arrow trimming. Kept
        /// narrow so labels don't bleed into each other's vertical bands.
        let labelWidth: CGFloat
        let labelAlignment: HorizontalAlignment
        let style: LineStyle
        let isPrimary: Bool
    }

    /// Layout principle: each arrow lives in its own horizontal x-column
    /// (target's x), and each label sits in a vertical band where no other
    /// arrow passes through it. Bottom three labels are pulled down close to
    /// their target buttons so the arrows are short and readable.
    private let items: [Item] = [
        Item(
            id: .addServer,
            primary: "add a remote computer",
            secondary: "if you have one",
            position: UnitPoint(x: 0.55, y: 0.20),
            labelWidth: 200,
            labelAlignment: .center,
            style: .smoothCurve,
            isPrimary: false
        ),
        Item(
            id: .search,
            primary: "see all\nyour threads",
            secondary: nil,
            position: UnitPoint(x: 0.92, y: 0.62),
            labelWidth: 110,
            labelAlignment: .trailing,
            style: .dashedSquiggle,
            isPrimary: false
        ),
        Item(
            id: .newThread,
            primary: "start a new thread",
            secondary: "or just type a message",
            position: UnitPoint(x: 0.50, y: 0.70),
            labelWidth: 220,
            labelAlignment: .center,
            style: .solidSquiggle,
            isPrimary: true
        ),
        Item(
            id: .voice,
            primary: "realtime voice",
            secondary: "needs OpenAI key in Settings",
            position: UnitPoint(x: 0.20, y: 0.78),
            labelWidth: 160,
            labelAlignment: .leading,
            style: .dotted,
            isPrimary: false
        )
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(items) { item in
                    if let rect = resolvedRect(for: item.id, in: proxy) {
                        coachmark(for: item, targetRect: rect, container: proxy.size)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    /// Resolve the on-screen rect for a target. Server pill, +, and search
    /// publish anchors from inside the dashboard subtree. The voice button
    /// is overlaid externally (in `LitterApp.primaryNavigationStack`) so its
    /// anchor never reaches us — fall back to a fixed position matching
    /// `homeVoiceLauncher`'s `.bottomLeading` placement (14pt leading inset,
    /// 4pt bottom inset, 44pt button size).
    private func resolvedRect(for target: CoachmarkTarget, in proxy: GeometryProxy) -> CGRect? {
        if let anchor = anchors[target] {
            return proxy[anchor]
        }
        if target == .voice {
            let size: CGFloat = 44
            let leading: CGFloat = 14
            let bottomInset: CGFloat = 4
            return CGRect(
                x: leading,
                y: proxy.size.height - bottomInset - size,
                width: size,
                height: size
            )
        }
        return nil
    }

    @ViewBuilder
    private func coachmark(for item: Item, targetRect: CGRect, container: CGSize) -> some View {
        let labelHeight: CGFloat = 60
        let target = CGPoint(x: targetRect.midX, y: targetRect.midY)

        // Place the label at its assigned absolute position, then clamp to
        // the container so it never overflows on a narrow device.
        let proposedX = container.width * item.position.x - item.labelWidth / 2
        let proposedY = container.height * item.position.y - labelHeight / 2
        let clampedX = min(max(8, proposedX), container.width - item.labelWidth - 8)
        let clampedY = min(max(8, proposedY), container.height - labelHeight - 8)
        let labelRect = CGRect(x: clampedX, y: clampedY, width: item.labelWidth, height: labelHeight)
        let labelCenter = CGPoint(x: labelRect.midX, y: labelRect.midY)

        ZStack(alignment: .topLeading) {
            // Halo ring for the primary target.
            if item.isPrimary {
                CoachmarkHalo()
                    .frame(width: targetRect.width + 18, height: targetRect.height + 18)
                    .position(x: target.x, y: target.y)
                    // Disable implicit animation on the position itself — the
                    // halo's TimelineView pulse must NOT trickle into the
                    // .position update, otherwise tiny anchor jitter from the
                    // glass-morph button gets interpolated across the full
                    // animation curve and reads as the halo flying around.
                    .transaction { $0.animation = nil }
            }

            CoachmarkArrow(
                from: labelCenter,
                to: target,
                targetRect: targetRect,
                labelRect: labelRect,
                style: item.style,
                isPrimary: item.isPrimary
            )

            VStack(alignment: item.labelAlignment, spacing: 2) {
                Text(item.primary)
                    .litterMonoFont(size: 12, weight: .semibold)
                    .foregroundStyle(LitterTheme.accent)
                    .multilineTextAlignment(textAlignment(for: item.labelAlignment))
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary = item.secondary {
                    Text(secondary)
                        .litterMonoFont(size: 10, weight: .regular)
                        .foregroundStyle(LitterTheme.textSecondary)
                        .multilineTextAlignment(textAlignment(for: item.labelAlignment))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .shadow(color: coachmarkTextShadowColor, radius: coachmarkTextShadowRadius, x: 0, y: 1)
            .frame(width: item.labelWidth, height: labelHeight, alignment: vstackFrameAlignment(for: item.labelAlignment))
            .position(x: labelCenter.x, y: labelCenter.y)
        }
    }

    private var coachmarkTextShadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.7) : .clear
    }

    private var coachmarkTextShadowRadius: CGFloat {
        colorScheme == .dark ? 4 : 0
    }

    private func textAlignment(for h: HorizontalAlignment) -> TextAlignment {
        switch h {
        case .leading:  return .leading
        case .trailing: return .trailing
        default:        return .center
        }
    }

    private func vstackFrameAlignment(for h: HorizontalAlignment) -> Alignment {
        switch h {
        case .leading:  return .topLeading
        case .trailing: return .topTrailing
        default:        return .top
        }
    }
}

/// Pulsing ring around the primary target. Uses `TimelineView` to drive the
/// animation from a wall-clock so SwiftUI's animation system never gets
/// involved — earlier `.animation(.repeatForever, value: pulse)` left an
/// active animation context in this subtree forever, causing every other
/// property change in the parent (notably `.position`) to interpolate over
/// the same 1.2s curve and visually fly across the screen.
private struct CoachmarkHalo: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            // Phase: 0..1, period 1.6s, sinusoidal so it eases at endpoints.
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 2 * .pi / 1.6) + 1) / 2

            let scale = 1.0 + 0.08 * phase
            let outerOpacity = 0.18 - 0.13 * phase
            let outerWidth = 4 + 4 * phase

            Circle()
                .stroke(LitterTheme.accent.opacity(0.7), lineWidth: 1.5)
                .background(
                    Circle()
                        .stroke(LitterTheme.accent.opacity(outerOpacity), lineWidth: outerWidth)
                        .blur(radius: 2)
                )
                .scaleEffect(scale)
        }
    }
}

/// Hand-drawn-feeling coachmark arrow. The path is either a smooth quadratic
/// curve (`smoothCurve`) or a sine-wave squiggle along the straight line
/// between `from` and `to`. Stroke style varies per item: solid, dashed, or
/// dotted (round-cap zero-length dashes). The wiggle amplitude tapers to
/// zero at each end so the arrowhead direction stays clean.
private struct CoachmarkArrow: View {
    let from: CGPoint
    let to: CGPoint
    let targetRect: CGRect
    let labelRect: CGRect
    let style: OnboardingCoachmarksView.LineStyle
    let isPrimary: Bool

    var body: some View {
        Canvas { ctx, _ in
            // Trim so the path starts outside the label box and ends with
            // clearance from the button so the arrowhead doesn't poke into
            // it. The target gap is wider for short arrows because the
            // arrowhead occupies a larger fraction of the visible line.
            let start = trimToRect(from: to, toward: from, rect: labelRect.insetBy(dx: -6, dy: -6))
            let endInset: CGFloat = (style == .smoothCurve) ? -11 : -6
            let end = trimToRect(from: from, toward: to, rect: targetRect.insetBy(dx: endInset, dy: endInset))

            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = max(1, sqrt(dx * dx + dy * dy))
            let ux = dx / length
            let uy = dy / length
            // Perpendicular unit vector (rotate 90°). Stable sign keeps the
            // wiggle on a consistent side of the line.
            let nx = -uy
            let ny = ux

            let path: Path
            switch style {
            case .smoothCurve:
                path = makeSmoothCurve(start: start, end: end, nx: nx, ny: ny, length: length)
            case .solidSquiggle, .dashedSquiggle, .dotted:
                let amplitude: CGFloat = squiggleAmplitude(for: style, length: length)
                path = makeSquigglePath(
                    start: start,
                    end: end,
                    dx: dx, dy: dy,
                    nx: nx, ny: ny,
                    length: length,
                    amplitude: amplitude
                )
            }

            ctx.stroke(
                path,
                with: .color(LitterTheme.accent.opacity(isPrimary ? 0.95 : 0.80)),
                style: strokeStyle(for: style, isPrimary: isPrimary)
            )

            // Arrowhead aligned with the underlying straight direction (the
            // squiggle's amplitude is zero at the end thanks to the taper,
            // so this matches the painted line's true tangent at the tip).
            let headLen: CGFloat = 8
            let headHalfWidth: CGFloat = 4.5
            let baseX = end.x - ux * headLen
            let baseY = end.y - uy * headLen
            let leftX = baseX + (-uy) * headHalfWidth
            let leftY = baseY + ux * headHalfWidth
            let rightX = baseX - (-uy) * headHalfWidth
            let rightY = baseY - ux * headHalfWidth

            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(x: leftX, y: leftY))
            head.addLine(to: CGPoint(x: rightX, y: rightY))
            head.closeSubpath()
            ctx.fill(head, with: .color(LitterTheme.accent.opacity(isPrimary ? 0.95 : 0.9)))
        }
    }

    private func squiggleAmplitude(for style: OnboardingCoachmarksView.LineStyle, length: CGFloat) -> CGFloat {
        // Skip squiggle on short arrows — looks like noise at small scale.
        guard length > 70 else { return 0 }
        switch style {
        case .solidSquiggle:  return 5.5
        case .dashedSquiggle: return 4.5
        case .dotted:         return 0       // straight dotted line — no waves
        case .smoothCurve:    return 0
        }
    }

    private func strokeStyle(for style: OnboardingCoachmarksView.LineStyle, isPrimary: Bool) -> StrokeStyle {
        switch style {
        case .smoothCurve:
            return StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        case .solidSquiggle:
            return StrokeStyle(lineWidth: isPrimary ? 1.8 : 1.4, lineCap: .round, lineJoin: .round)
        case .dashedSquiggle:
            return StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [5, 5])
        case .dotted:
            // dash[0] near 0 + round cap → renders as round dots spaced by dash[1].
            return StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round, dash: [0.01, 7])
        }
    }

    private func makeSquigglePath(
        start: CGPoint, end: CGPoint,
        dx: CGFloat, dy: CGFloat,
        nx: CGFloat, ny: CGFloat,
        length: CGFloat, amplitude: CGFloat
    ) -> Path {
        let waves: CGFloat = max(2, length / 44)
        let steps = max(40, Int(length / 3))
        var path = Path()
        path.move(to: start)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let baseX = start.x + dx * t
            let baseY = start.y + dy * t
            // Hann-window taper: 0 at t=0 and t=1, peak at t=0.5.
            let taper = sin(.pi * t)
            let phase = t * waves * 2 * .pi
            let amp = amplitude * sin(phase) * taper
            path.addLine(to: CGPoint(x: baseX + nx * amp, y: baseY + ny * amp))
        }
        return path
    }

    private func makeSmoothCurve(
        start: CGPoint, end: CGPoint,
        nx: CGFloat, ny: CGFloat,
        length: CGFloat
    ) -> Path {
        // Subtle curve only. The earlier `length * 0.18` produced a wide arc
        // that made short arrows (like addServer's ~80pt run to the pill)
        // sweep way out to the side before terminating.
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let bend = min(7, length * 0.06)
        let control = CGPoint(x: mid.x + nx * bend, y: mid.y + ny * bend)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    /// Walks from `from` toward `target` and returns the first point that
    /// falls outside `rect`'s perimeter — used to clip the line so it
    /// neither enters the label box nor overshoots into the target.
    private func trimToRect(from target: CGPoint, toward from: CGPoint, rect: CGRect) -> CGPoint {
        let dx = target.x - from.x
        let dy = target.y - from.y
        let length = max(1, sqrt(dx * dx + dy * dy))
        let ux = dx / length
        let uy = dy / length

        var t: CGFloat = 0
        let step: CGFloat = 1
        var probe = from
        let maxT = length
        while t <= maxT {
            if !rect.contains(probe) { return probe }
            probe.x += ux * step
            probe.y += uy * step
            t += step
        }
        return target
    }
}
