import SwiftUI

struct ContextBadgeView: View, Equatable {
    let percent: Int
    let tint: Color

    /// Plain mono percentage. Gray while healthy; the caller passes a
    /// warning/danger tint only when the budget is running low.
    var body: some View {
        Text("\(percent)%")
            .litterMeta(tint)
            .monospacedDigit()
            .accessibilityLabel("\(percent) percent remaining")
    }
}
