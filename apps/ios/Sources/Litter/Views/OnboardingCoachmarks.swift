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

/// Quiet first-run hints for the empty home screen.
///
/// Design rules: mono footnote (follows Dynamic Type), gray, lowercase, no
/// accent colour. The bottom-bar hints are one left-aligned block anchored
/// above the bottom buttons, wrapping within the container's 16pt gutters so
/// nothing clips or overlaps at any iPhone width or text size.
struct OnboardingCoachmarksView: View {
    let anchors: [CoachmarkTarget: Anchor<CGRect>]

    private let gutter: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                bottomHints(container: size, bottomTop: bottomBarTop(in: proxy))
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// Top edge of the bottom bar buttons, falling back to a conservative
    /// inset when the anchors are not published yet.
    private func bottomBarTop(in proxy: GeometryProxy) -> CGFloat {
        let tops = [CoachmarkTarget.newThread, .search].compactMap { anchors[$0].map { proxy[$0].minY } }
        return tops.min() ?? (proxy.size.height - 72)
    }

    private func bottomHints(container: CGSize, bottomTop: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            hint("+ start a thread, or just type")
            hint("search · all your threads")
            hint("voice · needs an openai key in settings")
        }
        .frame(width: max(0, container.width - gutter * 2), alignment: .leading)
        .frame(height: max(0, bottomTop - 40), alignment: .bottomLeading)
        .offset(x: gutter)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .litterMeta()
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
