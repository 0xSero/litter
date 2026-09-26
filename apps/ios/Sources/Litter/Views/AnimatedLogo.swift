import SwiftUI

/// Header brand mark: the static abstract cat at a fixed square size.
/// (Formerly a 120 Hz Canvas kitten animation; the fixed frame keeps the
/// toolbar height identical from the first frame.)
struct AnimatedLogo: View {
    var size: CGFloat = 44

    var body: some View {
        CatMark(width: size * 0.62, color: LitterTheme.textSecondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
