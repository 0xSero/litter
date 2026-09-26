import SwiftUI

/// The abstract Litter cat: a line-drawn cat sitting in its basket, as in
/// the Litter Quiet design (launch, empty Home, header mark). Pure vector
/// geometry in a 100 x 90 box, so it costs nothing to decode and follows
/// the user's theme color. Replaces the animated WebP cat and the Canvas
/// kitten animation.
struct CatMarkShape: Shape {
    static let aspectRatio: CGFloat = 100.0 / 90.0

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100
        let sy = rect.height / 90
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()

        // Head: sides rise out of the basket into two pointed ears joined
        // by a shallow crown.
        path.move(to: p(25, 52))
        path.addQuadCurve(to: p(28, 28), control: p(23, 38))
        path.addLine(to: p(30, 9))
        path.addLine(to: p(43, 21))
        path.addQuadCurve(to: p(57, 21), control: p(50, 18))
        path.addLine(to: p(70, 9))
        path.addLine(to: p(72, 28))
        path.addQuadCurve(to: p(75, 52), control: p(77, 38))

        // Closed, content eyes.
        path.move(to: p(36, 38))
        path.addQuadCurve(to: p(45, 38), control: p(40.5, 33))
        path.move(to: p(55, 38))
        path.addQuadCurve(to: p(64, 38), control: p(59.5, 33))

        // Small mouth.
        path.move(to: p(47, 44))
        path.addQuadCurve(to: p(50, 45.5), control: p(48.5, 46))
        path.addQuadCurve(to: p(53, 44), control: p(51.5, 46))

        // Basket: rim, bowl and two weave lines.
        path.move(to: p(8, 52))
        path.addLine(to: p(92, 52))
        path.move(to: p(12, 52))
        path.addQuadCurve(to: p(26, 84), control: p(14, 78))
        path.addLine(to: p(74, 84))
        path.addQuadCurve(to: p(88, 52), control: p(86, 78))
        path.move(to: p(16, 63))
        path.addLine(to: p(84, 63))
        path.move(to: p(20, 73))
        path.addLine(to: p(80, 73))

        return path
    }
}

/// Theme-colored cat mark at a fixed width. `fadeIn` plays one short
/// opacity fade the first time the mark appears; nothing repeats.
struct CatMark: View {
    var width: CGFloat = 96
    var color: Color = LitterTheme.textSecondary
    var fadeIn: Bool = false

    @State private var visible = false

    var body: some View {
        CatMarkShape()
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: max(1.25, width / 36),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: width, height: width / CatMarkShape.aspectRatio)
            .opacity(fadeIn && !visible ? 0 : 1)
            .onAppear {
                guard fadeIn, !visible else { return }
                withAnimation(.easeOut(duration: 0.3)) { visible = true }
            }
            .accessibilityHidden(true)
    }
}

/// Launch surface: theme background with the cat mark centered. Shown while
/// the Rust bridge and the first store snapshot load, so Home's first frame
/// already has its cached rows.
struct LaunchMarkView: View {
    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            CatMark(width: 104, fadeIn: true)
        }
        .accessibilityLabel("Starting Litter")
    }
}

#if DEBUG
#Preview("Cat mark") {
    VStack(spacing: 32) {
        CatMark(width: 104)
        CatMark(width: 28, color: LitterTheme.textPrimary)
    }
    .padding()
    .background(LitterTheme.backgroundGradient)
}
#endif
