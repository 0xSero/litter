import SwiftUI
import WidgetKit

/// Circular complication: small donut with RUN/IDLE eyebrow + big number.
///
/// Running: progress arc filled ginger, number is the current runtime.
/// Idle:    full ring muted, number is the connected server count.
struct LitterCircularComplication: Widget {
    let kind = "LitterCircularComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LitterComplicationProvider()) { entry in
            LitterCircularView(entry: entry)
                .widgetAccentable()
                .containerBackground(.clear, for: .widget)
        }
        .supportedFamilies([.accessoryCircular])
        .configurationDisplayName("Codex Glance")
        .description("Runtime of the current task, or connected server count when idle.")
    }
}

struct LitterCircularView: View {
    let entry: LitterComplicationEntry

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: entry.mode == .running ? entry.progress : 1)
                .stroke(
                    LitterComplicationTint.ginger,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text(entry.mode == .running ? "RUN" : entry.mode == .idle ? "IDLE" : "OFF")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(LitterComplicationTint.ginger)
                Text(primary)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .padding(2)
        .widgetURL(entry.taskId.flatMap { URL(string: "litter-watch://task/\($0)") })
    }

    private var primary: String {
        switch entry.mode {
        case .running: return entry.runtimeLabel(at: entry.date)
        case .idle:    return "\(entry.serverCount)"
        case .offline: return "—"
        }
    }
}

#Preview(as: .accessoryCircular) {
    LitterCircularComplication()
} timeline: {
    LitterComplicationEntry.placeholder
    LitterComplicationEntry.idlePlaceholder
}
