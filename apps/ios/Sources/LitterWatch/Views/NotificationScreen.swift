import SwiftUI
import UserNotifications

/// 6 · Notification long-look. Driven by the real push payload the phone
/// sent. watchOS passes us `UNNotification.request.content`; we pull title,
/// subtitle, body out of that.
///
/// Notification host controllers don't share the main app's environment,
/// so theme is consumed directly from `WatchThemeStore.shared` rather than
/// via `@EnvironmentObject`.
struct NotificationScreen: View {
    @ObservedObject private var theme = WatchThemeStore.shared
    let notification: UNNotification?

    init(notification: UNNotification? = nil) {
        self.notification = notification
    }

    var body: some View {
        let content = notification?.request.content

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(theme.accent)
                        .frame(width: 18, height: 18)
                    Text("L")
                        .font(WatchTheme.mono(10, weight: .bold))
                        .foregroundStyle(theme.textOnAccent)
                }
                Text("litter")
                    .font(WatchTheme.mono(10))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            }

            Text(content?.title ?? "codex update")
                .font(WatchTheme.mono(14, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = content?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(WatchTheme.mono(11))
                    .foregroundStyle(theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(content?.body ?? "")
                .font(WatchTheme.mono(11))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .containerBackground(theme.backgroundGradient, for: .navigation)
    }
}
