import SwiftUI
import UIKit
import UserNotifications
import Combine
import os

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var pendingPushToken: Data?
    private var pendingNotificationThreadKey: ThreadKey?
    private var splashWindow: UIWindow?
    private var minTimeElapsed = false
    private var contentReady = false
    private var splashDismissed = false

    weak var appRuntime: AppRuntimeController? {
        didSet {
            if let token = pendingPushToken {
                LLog.info("push", "delivering pending device token to runtime")
                appRuntime?.setDevicePushToken(token)
                pendingPushToken = nil
            }
            if let key = pendingNotificationThreadKey {
                LLog.info(
                    "push",
                    "delivering pending notification thread open to runtime",
                    fields: ["serverId": key.serverId, "threadId": key.threadId]
                )
                pendingNotificationThreadKey = nil
                openThreadFromNotification(key)
            }
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        OpenAIApiKeyStore.shared.applyToEnvironment()
        LitterPlatform.bootstrapLocalRuntimeIfNeeded()
        LLog.bootstrap()

        #if targetEnvironment(macCatalyst)
        // On unsandboxed Mac Catalyst, send the spawned codex child a
        // SIGTERM during termination so it does not outlive the app.
        // willTerminate runs on the main thread and gives ~5s; the
        // blocking variant detaches the actual stop off the main actor
        // so awaiting it does not deadlock.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            LocalCodexBootstrap.shared.stopBlocking(timeout: 2.5)
        }
        #endif

        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            LLog.info("lifecycle", "protected app data became available")
            OpenAIApiKeyStore.shared.applyToEnvironment()
            guard let appRuntime = self?.appRuntime else { return }
            Task { @MainActor in
                await appRuntime.restoreMissingLocalAuthStateIfNeeded()
            }
        }

        LLog.info("lifecycle", "application did finish launching")
        // Pre-initialize Rust bridges (tokio runtime) on a background thread
        // before SwiftUI accesses AppModel.shared, avoiding a priority inversion
        // where the main thread blocks on lower-QoS tokio worker init.
        DispatchQueue.global(qos: .userInitiated).async {
            AppModel.prewarmRustBridges()
        }
        application.registerForRemoteNotifications()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: "litter.task.complete",
                actions: [],
                intentIdentifiers: [],
                options: [.allowAnnouncement]
            ),
            UNNotificationCategory(
                identifier: WatchApprovalNotification.categoryIdentifier,
                actions: [
                    UNNotificationAction(
                        identifier: WatchApprovalNotification.allowActionIdentifier,
                        title: "Allow",
                        options: []
                    ),
                    UNNotificationAction(
                        identifier: WatchApprovalNotification.denyActionIdentifier,
                        title: "Deny",
                        options: [.destructive]
                    ),
                ],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
        ])
        OrientationResponder.shared.start()
        DispatchQueue.main.async {
            CloudKVSBridge.shared.start()
        }
        showSplashWindow()
        scheduleKeyboardWarmup()
        // Start pushing state to the paired Apple Watch, gated behind the
        // experimental feature flag. Flip the `appleWatch` feature in
        // Settings → Experimental Features to enable. No-op when disabled.
        DispatchQueue.main.async {
            if ExperimentalFeatures.shared.isEnabled(.appleWatch) {
                WatchCompanionBridge.shared.start()
            }
        }
        return true
    }

    // MARK: - Splash window (sits above keyboard)

    private func showSplashWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                self.showSplashWindow()
                return
            }
            let window = UIWindow(windowScene: scene)
            // Keyboard window is typically at level ~10000. Go above it.
            window.windowLevel = UIWindow.Level(rawValue: 10000002)
            let hosting = UIHostingController(rootView:
                AnimatedSplashView(appReady: true) {}
            )
            hosting.view.backgroundColor = .clear
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            self.splashWindow = window

            // Minimum display time
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.minTimeElapsed = true
                self.tryDismissSplash()
            }
            // Hard max
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.forceDismissSplash()
            }
        }
    }

    /// Called by ContentView when the main UI has appeared.
    func signalContentReady() {
        contentReady = true
        tryDismissSplash()
    }

    private func tryDismissSplash() {
        guard !splashDismissed, minTimeElapsed, contentReady else { return }
        dismissSplash()
    }

    private func forceDismissSplash() {
        guard !splashDismissed else { return }
        dismissSplash()
    }

    private func dismissSplash() {
        splashDismissed = true
        guard let window = splashWindow else { return }
        UIView.animate(withDuration: 0.35, animations: {
            window.alpha = 0
        }, completion: { _ in
            window.isHidden = true
            window.rootViewController = nil
            self.splashWindow = nil
        })
    }

    // MARK: - Keyboard warmup

    private func scheduleKeyboardWarmup() {
        // Load the real system keyboard while the splash window covers it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first(where: { $0 !== self.splashWindow }) else {
                self.scheduleKeyboardWarmup()
                return
            }
            let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            window.addSubview(field)
            field.becomeFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                field.resignFirstResponder()
                field.removeFromSuperview()
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        LLog.info("push", "device token received", fields: ["bytes": deviceToken.count, "hex": hex])
        if let appRuntime {
            appRuntime.setDevicePushToken(deviceToken)
        } else {
            pendingPushToken = deviceToken
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        LLog.error("push", "registration failed", error: error)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Best-effort graceful shutdown of the iroh endpoint. iOS only
        // fires this hook reliably on Catalyst (NSApplicationDelegate)
        // and on OS-initiated terminations from background — swipe-up-
        // to-kill from app switcher does NOT fire it. Acceptable: the
        // cost of skipping is one "Aborting ungracefully" log on iroh's
        // side and the daemon waiting up to its idle timeout to reap
        // the final zombie.
        LLog.info("lifecycle", "applicationWillTerminate — closing alleycat endpoint")
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await self.appRuntime?.shutdownAlleycatEndpoint()
            semaphore.signal()
        }
        // applicationWillTerminate gets ~5s before the OS kills us.
        // Block briefly on the close handshake so iroh can flush
        // CONNECTION_CLOSE frames; bail if iroh's drain takes too long.
        _ = semaphore.wait(timeout: .now() + 2.5)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        LLog.info(
            "push",
            "background push received",
            fields: [
                "applicationState": application.applicationState.debugName
            ],
            payloadJson: notificationPayloadJson(userInfo)
        )
        if application.applicationState == .active {
            LLog.info("push", "skipping background push handler because app is already active")
            completionHandler(.noData)
            return
        }
        guard let appRuntime else {
            LLog.warn("push", "background push received before runtime was ready")
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await appRuntime.handleBackgroundPush()
            LLog.info("push", "background push handling completed", fields: ["result": "newData"])
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        LLog.info(
            "push",
            "user opened notification",
            payloadJson: notificationPayloadJson(response.notification.request.content.userInfo)
        )

        let info = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        if actionId == WatchApprovalNotification.allowActionIdentifier ||
            actionId == WatchApprovalNotification.denyActionIdentifier,
            let requestId = info[WatchApprovalNotification.requestIdKey] as? String {
            let approve = actionId == WatchApprovalNotification.allowActionIdentifier
            Task { @MainActor in
                do {
                    try await AppModel.shared.store.respondToApproval(
                        requestId: requestId,
                        decision: approve ? .accept : .decline
                    )
                } catch {
                    LLog.error(
                        "push",
                        "approval action dispatch failed: \(error.localizedDescription)"
                    )
                }
                completionHandler()
            }
            return
        }

        if let key = AppLifecycleController.notificationThreadKey(
            from: response.notification.request.content.userInfo
        ) {
            openThreadFromNotification(key)
        }
        completionHandler()
    }

    private func openThreadFromNotification(_ key: ThreadKey) {
        LLog.info(
            "push",
            "open thread from notification",
            fields: ["serverId": key.serverId, "threadId": key.threadId]
        )
        if appRuntime == nil {
            pendingNotificationThreadKey = key
            return
        }

        Task { @MainActor [weak self] in
            guard let self, let appRuntime = self.appRuntime else { return }
            await appRuntime.openThreadFromNotification(key: key)
        }
    }

    private func notificationPayloadJson(_ userInfo: [AnyHashable: Any]) -> String? {
        guard !userInfo.isEmpty else { return nil }
        let payload = Dictionary(uniqueKeysWithValues: userInfo.map { key, value in
            (String(describing: key), String(describing: value))
        })
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }
}

@main
struct LitterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel.shared
    @State private var voiceRuntime = VoiceRuntimeController.shared
    @State private var appRuntime = AppRuntimeController.shared
    @State private var themeManager = ThemeManager.shared
    @State private var wallpaperManager = WallpaperManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @SceneBuilder
    var body: some Scene {
        #if targetEnvironment(macCatalyst)
        mainWindowGroup
            .defaultSize(width: 1120, height: 760)
            // NOTE: `.windowResizability` is a no-op on Catalyst.
            // Actual resize bounds are set from
            // `MacWindowTitleBarStyler` via
            // `UIWindowScene.sizeRestrictions`.
            .commands {
                LitterCommands(appModel: appModel)
            }
        #else
        mainWindowGroup
        #endif
    }

    private var mainWindowGroup: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(appRuntime)
                .environment(voiceRuntime)
                .environment(themeManager)
                .environment(wallpaperManager)
                .task {
                    appModel.start()
                    voiceRuntime.bind(appModel: appModel)
                    appRuntime.bind(appModel: appModel, voiceRuntime: voiceRuntime)
                    appDelegate.appRuntime = appRuntime
                    appRuntime.appDidBecomeActive()
                    #if targetEnvironment(macCatalyst)
                    LocalCodexBootstrap.shared.startIfNeeded(appModel: appModel)
                    #endif
                    // Pair host (BLE advertiser, ultrasonic emitter,
                    // Bonjour publish, WS listener) and the iPhone client
                    // (BLE scanner, ultrasonic reader, NISession) are
                    // strictly opt-in: they only start when the user
                    // opens the Pair screen in Settings → Experimental,
                    // and stop on disappear. The screen itself is gated
                    // behind `#if DEBUG`, so neither stack is reachable
                    // in Release builds.
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            LLog.info("lifecycle", "scenePhase changed", fields: ["phase": newPhase.debugName])
            switch newPhase {
            case .background:
                appRuntime.appDidEnterBackground()
            case .inactive:
                appRuntime.appDidBecomeInactive()
            case .active:
                appRuntime.appDidBecomeActive()
            default:
                break
            }
        }
    }
}

private extension UIApplication.State {
    var debugName: String {
        switch self {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}

private extension ScenePhase {
    var debugName: String {
        switch self {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppRuntimeController.self) private var appRuntime
    @Environment(ThemeManager.self) private var themeManager
    @State private var appState = AppState()
    @State private var stableSafeAreaInsets = StableSafeAreaInsets()
    @State private var conversationWarmup = ConversationWarmupCoordinator()
    @State private var petOverlay = PetOverlayController.shared
    @State private var composerBottomInset: CGFloat = 0
    @State private var splashDismissed = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("conversationTextSizeStep") private var textSizeStep = ConversationTextSize.large.rawValue

    private var textScale: CGFloat {
        ConversationTextSize.clamped(rawValue: textSizeStep).scale
    }

    var body: some View {
        @Bindable var bindableAppState = appState

        GeometryReader { geometry in
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()

                #if DEBUG
                if ConversationDisplayUITestHarnessView.isEnabled {
                    ConversationDisplayUITestHarnessView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    standardHomeNavigationView(
                        topInset: geometry.safeAreaInsets.top,
                        bottomInset: composerBottomInset
                    )
                }
                #else
                standardHomeNavigationView(
                    topInset: geometry.safeAreaInsets.top,
                    bottomInset: composerBottomInset
                )
                #endif

                #if DEBUG
                if !ConversationDisplayUITestHarnessView.isEnabled {
                    standardOverlays
                }
                #else
                standardOverlays
                #endif

            }
            .ignoresSafeArea(.container)
            .task {
                if composerBottomInset <= 0, geometry.safeAreaInsets.bottom > 0 {
                    composerBottomInset = geometry.safeAreaInsets.bottom
                }
                stableSafeAreaInsets.start(
                    fallback: max(composerBottomInset, geometry.safeAreaInsets.bottom)
                )
            }
            .onChange(of: stableSafeAreaInsets.bottomInset) { (_: CGFloat, nextInset: CGFloat) in
                guard nextInset > 0 else { return }
                composerBottomInset = nextInset
            }
        }
        .environment(appState)
        .environment(conversationWarmup)
        .environment(\.textScale, textScale)
        .preferredColorScheme(themeManager.appearanceMode.preferredColorScheme)
        .background {
            InterfaceStyleSynchronizer(style: themeManager.appearanceMode.userInterfaceStyle)
                .frame(width: 0, height: 0)
        }
        #if targetEnvironment(macCatalyst)
        .background {
            MacWindowTitleBarStyler()
        }
        #endif
        .onAppear {
            themeManager.syncSystemColorScheme(colorScheme)
            let forceDiscoveryForUITest =
                ProcessInfo.processInfo.environment["CODEXIOS_UI_TEST_FORCE_DISCOVERY"] == "1"
            if forceDiscoveryForUITest {
                appState.showServerPicker = true
            }
        }
        .onChange(of: colorScheme) { _, nextColorScheme in
            // iOS toggles `colorScheme` while capturing light+dark
            // app-switcher snapshots on background. Reacting to that
            // bumps `themeManager.themeVersion`, which the navigation
            // root uses as `.id(...)` and would tear down every
            // in-flight @State (composer text, focus, scroll) every
            // time the user switches apps. Only react when the scene
            // is actually active — i.e., a real user theme toggle.
            guard scenePhase == .active else { return }
            themeManager.syncSystemColorScheme(nextColorScheme)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Catch up to any colorScheme change that landed while we
            // were inactive but represents a real user-driven theme
            // toggle (e.g. system appearance changed in Settings while
            // the app was backgrounded).
            if newPhase == .active {
                themeManager.syncSystemColorScheme(colorScheme)
            }
        }
        .onChange(of: appModel.snapshot?.activeThread) { _, _ in
            appState.selectedModel = ""
            appState.selectedAgentRuntimeKind = nil
            appState.reasoningEffort = ""
            appState.showModelSelector = false
        }
        .onChange(of: appModel.snapshot) { _, nextSnapshot in
            appRuntime.handleSnapshot(nextSnapshot)
        }
        .sheet(isPresented: $bindableAppState.showServerPicker) {
            NavigationStack {
                DiscoveryView(onServerSelected: { _ in
                    appState.showServerPicker = false
                })
            }
            .environment(appModel)
            .environment(appState)
            .environment(\.textScale, textScale)
        }
        .sheet(isPresented: $bindableAppState.showSettings) {
            SettingsView()
                .environment(appModel)
                .environment(appState)
                .environment(themeManager)
                .environment(\.textScale, textScale)
                .background {
                    InterfaceStyleSynchronizer(style: themeManager.appearanceMode.userInterfaceStyle)
                        .frame(width: 0, height: 0)
                }
        }
        #if targetEnvironment(macCatalyst)
        .onReceive(NotificationCenter.default.publisher(for: .litterCommandShowSettings)) { _ in
            appState.showSettings = true
        }
        #endif
    }

    private func standardHomeNavigationView(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        HomeNavigationView(
            topInset: topInset,
            bottomInset: bottomInset
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .id(themeManager.themeVersion)
        .onAppear {
            if !splashDismissed {
                splashDismissed = true
                (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
            }
        }
    }

    @ViewBuilder
    private var standardOverlays: some View {
        if petOverlay.visible, let pet = petOverlay.selectedPet {
            PetOverlayView(
                pet: pet,
                state: petOverlay.avatarState(snapshot: appModel.snapshot),
                message: petOverlay.avatarMessage(snapshot: appModel.snapshot),
                reduceMotion: UIAccessibility.isReduceMotionEnabled
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        if let approval = appModel.snapshot?.pendingApprovals.first(where: {
            $0.kind != .mcpElicitation
        }) {
            ApprovalPromptView(approval: approval) { decision in
                Task {
                    try? await appModel.store.respondToApproval(
                        requestId: approval.id,
                        decision: decision
                    )
                }
            } onViewThread: { threadKey in
                appState.pendingThreadNavigation = threadKey
            }
        }

        if let warmupID = conversationWarmup.activeWarmupID {
            ConversationWarmupView(warmupID: warmupID) {
                conversationWarmup.finishWarmup()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct InterfaceStyleSynchronizer: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> InterfaceStyleSyncView {
        let view = InterfaceStyleSyncView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.targetStyle = style
        return view
    }

    func updateUIView(_ uiView: InterfaceStyleSyncView, context: Context) {
        uiView.targetStyle = style
    }

    final class InterfaceStyleSyncView: UIView {
        var targetStyle: UIUserInterfaceStyle = .unspecified {
            didSet { applyStyleIfNeeded() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyStyleIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.applyStyleIfNeeded()
            }
        }

        private func applyStyleIfNeeded() {
            guard let window else { return }
            if window.overrideUserInterfaceStyle != targetStyle {
                window.overrideUserInterfaceStyle = targetStyle
            }
            guard let windowScene = window.windowScene else { return }
            for sceneWindow in windowScene.windows where sceneWindow.overrideUserInterfaceStyle != targetStyle {
                sceneWindow.overrideUserInterfaceStyle = targetStyle
            }
        }
    }
}

private let homeNavigationSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "HomeNavigation"
)

private let conversationRouteSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "ConversationRoute"
)

private struct HomeNavigationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(VoiceRuntimeController.self) private var voiceRuntime
    @Environment(AppState.self) private var appState
    @Environment(ConversationWarmupCoordinator.self) private var conversationWarmup
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var experimentalFeatures = ExperimentalFeatures.shared
    @State private var homeDashboardModel = HomeDashboardModel()
    @State private var savedAppsStore = SavedAppsStore.shared
    @State private var navigationPath: [HomeNavigationRoute] = []
    @State private var directoryPickerSheet: SessionLaunchSupport.DirectoryPickerSheetModel?
    @State private var showProjectPicker = false
    @State private var openingRecentSessionKey: ThreadKey?
    @State private var isStartingNewSession = false
    @State private var isStartingVoice = false
    @State private var actionErrorMessage: String?
    @State private var homeInputMode: HomeInputMode = .collapsed
    @State private var hydratingPinnedHomeThreadIds: Set<String> = []
    @State private var pinnedThreadListingRepairTasks: [String: Task<Bool, Never>] = [:]
    @State private var hasSeededInitialConversationRoute = false
    @State private var pendingWallpaperConfig: WallpaperConfig?
    @State private var pendingWallpaperImage: UIImage?
    let topInset: CGFloat
    let bottomInset: CGFloat

    private enum HomeNavigationRoute: Hashable {
        case sessions(serverId: String, title: String)
        case conversation(ThreadKey)
        case realtimeVoice(ThreadKey)
        case conversationInfo(ThreadKey)
        case wallpaperSelection(ThreadKey)
        case wallpaperAdjust(ThreadKey)
        case serverInfo(serverId: String)
        case serverWallpaperSelection(serverId: String)
        case serverWallpaperAdjust(serverId: String)
        case replayRecording(URL)
        /// Hero composer landing in the detail pane. Pushed by the sidebar
        /// "+" button on regular-width surfaces. On send, replaces itself
        /// with `.conversation(key)` so the bottom composer visually
        /// inherits the hero composer's position.
        case newThread
        /// Saved apps list — always-visible.
        case appsList
        /// Saved-app detail, pushed when the user taps a home-screen thread
        /// that has saved apps (or when routed from the AppsList).
        case savedApp(appId: String)
        /// Local on-device terminal backed by the shared Rust terminal session.
        case terminal(preferredAlleycatNodeId: String?)
    }

    private var connectedServerOptions: [DirectoryPickerServerOption] {
        homeDashboardModel.connectedServers.filter(\.canLaunchSessions).map { server in
            DirectoryPickerServerOption(
                id: server.id,
                name: server.displayName,
                sourceLabel: server.sourceLabel
            )
        }
    }

    private var isHomeRouteActive: Bool {
        navigationPath.isEmpty
    }

    private var terminalLauncher: (() -> Void)? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        guard experimentalFeatures.isEnabled(.terminal) else { return nil }
        return { navigationPath.append(.terminal(preferredAlleycatNodeId: nil)) }
        #endif
    }

    private var pinnedThreadHydrationSignature: String {
        let pins = homeDashboardModel.pinnedKeys
            .map { "\($0.serverId)/\($0.threadId)" }
            .joined(separator: "|")
        let pinnedSet = Set(homeDashboardModel.pinnedKeys)
        let servers = appModel.snapshot?.servers
            .map { "\($0.serverId)=\(String(describing: $0.transportState)):\($0.port)" }
            .joined(separator: "|") ?? ""
        let sessions = appModel.snapshot?.sessionSummaries
            .compactMap { summary -> String? in
                guard pinnedSet.contains(PinnedThreadKey(threadKey: summary.key)) else { return nil }
                return "\(homeHydrationId(summary.key)):\(summary.isResumed)"
            }
            .joined(separator: "|")
            ?? ""
        return "\(pins)|\(servers)|\(sessions)"
    }

    @ViewBuilder
    private var rootNavigationContent: some View {
        if LitterPlatform.isRegularSurface(horizontalSizeClass: horizontalSizeClass) {
            splitRoot
        } else {
            primaryNavigationStack
        }
    }

    private var splitRoot: some View {
        NavigationSplitView {
            sidebarDashboard
                // Apply Liquid Glass material explicitly to the sidebar
                // column. Catalyst 26 doesn't automatically paint the
                // sidebar with glass the way iPadOS does, so the column
                // comes through flat unless we install the material
                // ourselves. `.ultraThinMaterial` gives the proper
                // sidebar frosted-glass look with subtle vibrancy.
                .containerBackground(.ultraThinMaterial, for: .navigation)
        } detail: {
            primaryNavigationStack
        }
    }

    /// Whether the primary navigation stack is embedded as the detail pane
    /// of a `NavigationSplitView`. In that case the sidebar already hosts
    /// `HomeDashboardView`, so the detail pane's root should be an empty
    /// welcome surface instead of a second dashboard rendering.
    private var isEmbeddedInSplit: Bool {
        LitterPlatform.isRegularSurface(horizontalSizeClass: horizontalSizeClass)
    }

    private var primaryNavigationStack: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if isHomeRouteActive {
                    if isEmbeddedInSplit {
                        splitDetailRoot
                    } else {
                        homeDashboard
                    }
                } else {
                    LitterTheme.backgroundGradient.ignoresSafeArea()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isHomeRouteActive,
                   experimentalFeatures.isEnabled(.realtimeVoice),
                   homeInputMode == .collapsed {
                    homeVoiceLauncher
                }
            }
            .navigationDestination(for: HomeNavigationRoute.self) { route in
                switch route {
                case let .sessions(serverId, title):
                    SessionsScreen(
                        onOpenConversation: { key in
                            openConversation(key)
                        },
                        onInfo: {
                            navigationPath.append(.serverInfo(serverId: serverId))
                        }
                    )
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                        .onAppear {
                            appState.sessionsSelectedServerFilterId = serverId
                            appState.sessionsShowOnlyForks = false
                        }
                case let .conversation(threadKey):
                    ConversationDestinationScreen(
                        threadKey: threadKey,
                        bottomInset: bottomInset,
                        onResumeSessions: { showSessions(for: $0) },
                        onOpenConversation: { replaceTopConversation(with: $0) },
                        onInfo: { navigationPath.append(.conversationInfo(threadKey)) }
                    )
                case .newThread:
                    NewThreadHeroView(
                        project: homeDashboardModel.selectedProject,
                        connectedServers: homeDashboardModel.connectedServers,
                        selectedServerId: homeDashboardModel.selectedServerId,
                        onSelectServer: { serverId in
                            homeDashboardModel.selectedServerId = serverId
                        },
                        onOpenProjectPicker: { showProjectPicker = true },
                        onThreadCreated: { key in
                            homeDashboardModel.pinThread(key)
                            replaceHeroWithConversation(key: key)
                        },
                        onCancel: {
                            if case .newThread = navigationPath.last {
                                navigationPath.removeLast()
                            }
                        }
                    )
                case let .replayRecording(recordingUrl):
                    ReplayDestinationScreen(
                        recordingUrl: recordingUrl,
                        bottomInset: bottomInset
                    )
                case let .realtimeVoice(threadKey):
                    RealtimeVoiceScreen(
                        threadKey: threadKey,
                        onEnd: {
                            popCurrentRoute()
                            Task { await voiceRuntime.stopActiveVoiceSession() }
                        },
                        onToggleSpeaker: {
                            Task { try? await voiceRuntime.toggleActiveVoiceSessionSpeaker() }
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                case let .conversationInfo(threadKey):
                    ConversationInfoView(
                        threadKey: threadKey,
                        serverId: nil,
                        onOpenWallpaper: { navigationPath.append(.wallpaperSelection(threadKey)) },
                        onOpenConversation: { replaceTopConversation(with: $0) }
                    )
                case let .wallpaperSelection(threadKey):
                    WallpaperSelectionView(
                        threadKey: threadKey,
                        onSelectWallpaper: { config, image in
                            pendingWallpaperConfig = config
                            pendingWallpaperImage = image
                            navigationPath.append(.wallpaperAdjust(threadKey))
                        },
                        onClose: {
                            // Pop back to conversation info
                            popToConversationInfo()
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                case let .wallpaperAdjust(threadKey):
                    WallpaperAdjustView(
                        threadKey: threadKey,
                        initialConfig: pendingWallpaperConfig ?? WallpaperConfig(),
                        customImage: pendingWallpaperImage,
                        onDone: {
                            // Pop back to conversation info
                            popToConversationInfo()
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                case let .serverInfo(serverId):
                    ConversationInfoView(
                        threadKey: nil,
                        serverId: serverId,
                        onOpenWallpaper: { navigationPath.append(.serverWallpaperSelection(serverId: serverId)) },
                        onOpenShell: remoteShellLauncher(for: serverId)
                    )
                case let .serverWallpaperSelection(serverId):
                    WallpaperSelectionView(
                        threadKey: nil,
                        serverId: serverId,
                        onSelectWallpaper: { config, image in
                            pendingWallpaperConfig = config
                            pendingWallpaperImage = image
                            navigationPath.append(.serverWallpaperAdjust(serverId: serverId))
                        },
                        onClose: {
                            popToServerInfo()
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                case let .serverWallpaperAdjust(serverId):
                    WallpaperAdjustView(
                        threadKey: nil,
                        serverId: serverId,
                        initialConfig: pendingWallpaperConfig ?? WallpaperConfig(),
                        customImage: pendingWallpaperImage,
                        onDone: {
                            popToServerInfo()
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                case .appsList:
                    AppsListView()
                case .savedApp(let appId):
                    SavedAppDetailView(appId: appId)
                case let .terminal(preferredAlleycatNodeId):
                    TerminalScreen(
                        cwd: preferredTerminalWorkingDirectory(),
                        preferredAlleycatNodeId: preferredAlleycatNodeId
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    var body: some View {
        rootNavigationContent
        .task {
            homeDashboardModel.bind(appModel: appModel)
            updateHomeDashboardActivity()
            hydratePinnedThreadsIfNeeded()
            seedInitialConversationIfNeeded(activeKey: appModel.snapshot?.activeThread)
        }
        .onChange(of: appModel.snapshot?.activeThread) { _, newKey in
            seedInitialConversationIfNeeded(activeKey: newKey)
        }
        .onChange(of: navigationPath.count) { _, _ in
            updateHomeDashboardActivity()
        }
        .onChange(of: pinnedThreadHydrationSignature) { _, _ in
            hydratePinnedThreadsIfNeeded()
        }
        .onChange(of: appState.pendingThreadNavigation) { _, newKey in
            if let newKey {
                appState.pendingThreadNavigation = nil
                replaceTopConversation(with: newKey)
            }
        }
        .onChange(of: SavedAppsNavigation.shared.pendingConversationThreadId) { _, newThreadId in
            guard let newThreadId else { return }
            _ = SavedAppsNavigation.shared.consumeConversationRequest()
            guard let key = appModel.snapshot?.threads.first(where: { $0.key.threadId == newThreadId })?.key else {
                return
            }
            // Pop the saved-app detail off the stack, then push the conversation.
            if case .savedApp = navigationPath.last {
                navigationPath.removeLast()
            }
            openConversation(key)
        }
        #if targetEnvironment(macCatalyst)
        .onReceive(NotificationCenter.default.publisher(for: .litterCommandNewSession)) { _ in
            handleNewSessionTap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .litterCommandNavigateBack)) { _ in
            if !navigationPath.isEmpty { navigationPath.removeLast() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .litterCommandNavigateForward)) { _ in
            if let activeKey = appModel.snapshot?.activeThread,
               navigationPath.last != .conversation(activeKey) {
                navigationPath.append(.conversation(activeKey))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .litterCommandSelectSession)) { notification in
            guard let index = notification.userInfo?["index"] as? Int,
                  let summaries = appModel.snapshot?.sessionSummaries,
                  summaries.indices.contains(index) else { return }
            Task { @MainActor in
                await openSessionAtIndex(summaries[index])
            }
        }
        #endif
        .sheet(item: $directoryPickerSheet) { _ in
            NavigationStack {
                DirectoryPickerView(
                    servers: connectedServerOptions,
                    selectedServerId: Binding(
                        get: { directoryPickerSheet?.selectedServerId ?? defaultNewSessionServerId() ?? "" },
                        set: { nextServerId in
                            guard var sheet = directoryPickerSheet else { return }
                            sheet.selectedServerId = nextServerId
                            directoryPickerSheet = sheet
                        }
                    ),
                    onServerChanged: { nextServerId in
                        guard var sheet = directoryPickerSheet else { return }
                        sheet.selectedServerId = nextServerId
                        directoryPickerSheet = sheet
                    },
                    onDirectorySelected: { serverId, cwd in
                        directoryPickerSheet = nil
                        createAndSelectProject(serverId: serverId, cwd: cwd)
                    },
                    onDismissRequested: {
                        directoryPickerSheet = nil
                    }
                )
            }
            .environment(appModel)
        }
        .sheet(isPresented: $showProjectPicker) {
            ProjectPickerSheet(
                projects: homeDashboardModel.projects,
                serverNamesById: Dictionary(uniqueKeysWithValues: homeDashboardModel.connectedServers.map { ($0.id, $0.displayName) }),
                onSelect: { project in
                    homeDashboardModel.selectedServerId = project.serverId
                    homeDashboardModel.selectedProject = project
                },
                onCreateNew: {
                    showProjectPicker = false
                    let defaultServerId = homeDashboardModel.selectedServerId ?? defaultNewSessionServerId()
                    if let defaultServerId {
                        directoryPickerSheet = SessionLaunchSupport.DirectoryPickerSheetModel(selectedServerId: defaultServerId)
                    } else {
                        appState.showServerPicker = true
                    }
                }
            )
            .environment(appModel)
        }
        .alert("Home Action Failed", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "Unknown error")
        }
    }

    private func defaultNewSessionServerId(preferredServerId: String? = nil) -> String? {
        SessionLaunchSupport.defaultConnectedServerId(
            connectedServerIds: connectedServerOptions.map(\.id),
            activeThreadKey: appModel.snapshot?.activeThread,
            preferredServerId: preferredServerId
        )
    }

    private func createAndSelectProject(serverId: String, cwd: String) {
        homeDashboardModel.selectFreshProject(serverId: serverId, cwd: cwd)
        RecentDirectoryStore.shared.record(path: cwd, for: serverId)
    }

    private func handleNewSessionTap() {
        if let defaultServerId = defaultNewSessionServerId(preferredServerId: appState.sessionsSelectedServerFilterId) {
            // For local on-device server, skip directory picker and use /home/codex.
            if let server = homeDashboardModel.connectedServers.first(where: { $0.id == defaultServerId }),
               server.isLocal {
                let cwd = LitterPlatform.defaultLocalWorkingDirectory()
                Task { await startNewSession(serverId: defaultServerId, cwd: cwd) }
                return
            }
            directoryPickerSheet = SessionLaunchSupport.DirectoryPickerSheetModel(selectedServerId: defaultServerId)
        } else {
            appState.showServerPicker = true
        }
    }

    private var homeVoiceLauncher: some View {
        HomeVoiceOrbButton(
            session: voiceRuntime.activeVoiceSession,
            isAvailable: true,
            isStarting: isStartingVoice,
            action: startHomeVoiceSession
        )
        // Match the bottom inset used by `HomeBottomBar` inside
        // `HomeDashboardView.bottomChrome` so the mic button sits on the
        // same horizontal line as the `+` and search pills on the right.
        .padding(.leading, 14)
        .padding(.bottom, 4)
    }

    private func startHomeVoiceSession() {
        guard !isStartingVoice else { return }
        isStartingVoice = true
        actionErrorMessage = nil

        Task {
            do {
                let selectedModel = normalizedPreferredModel()
                let selectedEffort = appState.preferredReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                voiceRuntime.handoffModel = selectedModel
                voiceRuntime.handoffEffort = selectedEffort.isEmpty ? nil : selectedEffort
                voiceRuntime.handoffFastMode = false
                let voicePermissions = await voicePermissionConfig()
                let voiceKey = try await voiceRuntime.startPinnedLocalVoiceCall(
                    cwd: preferredVoiceWorkingDirectory(),
                    model: selectedModel,
                    approvalPolicy: voicePermissions.approvalPolicy,
                    sandboxMode: voicePermissions.sandboxMode
                )
                await MainActor.run {
                    openRealtimeVoice(voiceKey)
                }
            } catch {
                await MainActor.run {
                    actionErrorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                isStartingVoice = false
            }
        }
    }

    private func normalizedPreferredModel() -> String? {
        let trimmed = appState.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func preferredVoiceWorkingDirectory() -> String {
        let current = appState.currentCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            return current
        }

        let stored = UserDefaults.standard.string(forKey: "workDir")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty {
            return stored
        }

        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    }

    private func preferredTerminalWorkingDirectory() -> String? {
        let current = appState.currentCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }

        let stored = workDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }

        return nil
    }

    private func remoteShellLauncher(for serverId: String) -> (() -> Void)? {
        guard experimentalFeatures.isEnabled(.terminal),
              let nodeId = savedAlleycatNodeId(for: serverId) else {
            return nil
        }
        return {
            navigationPath.append(.terminal(preferredAlleycatNodeId: nodeId))
        }
    }

    private func savedAlleycatNodeId(for serverId: String) -> String? {
        guard let saved = SavedServerStore.rememberedServers().first(where: { $0.id == serverId }),
              let nodeId = normalizedNonEmpty(saved.alleycatNodeId),
              let token = try? AlleycatCredentialStore.shared.loadToken(nodeId: nodeId),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return nodeId
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func openServerSessions(_ server: HomeDashboardServer) {
        appState.sessionsSelectedServerFilterId = server.id
        appState.sessionsShowOnlyForks = false
        hasSeededInitialConversationRoute = true
        navigationPath.append(.sessions(serverId: server.id, title: server.displayName))
    }

    private func openSessionAtIndex(_ summary: AppSessionSummary) async {
        guard openingRecentSessionKey == nil else { return }
        openingRecentSessionKey = summary.key
        actionErrorMessage = nil
        defer { openingRecentSessionKey = nil }

        await conversationWarmup.prewarmIfNeeded()
        workDir = summary.cwd
        appState.currentCwd = summary.cwd
        do {
            let resumeKey = await appModel.hydrateThreadPermissions(for: summary.key, appState: appState)
                ?? summary.key
            let nextKey = try await appModel.resumeThread(
                key: resumeKey,
                launchConfig: launchConfig(for: resumeKey),
                cwdOverride: summary.cwd
            )
            appModel.activateThread(nextKey)
            replaceTopConversation(with: nextKey)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func openRecentSession(_ thread: HomeDashboardRecentSession) async {
        guard openingRecentSessionKey == nil else { return }

        openingRecentSessionKey = thread.key
        actionErrorMessage = nil
        defer { openingRecentSessionKey = nil }

        await conversationWarmup.prewarmIfNeeded()
        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        let openedKey: ThreadKey?
        do {
            let resumeKey = await appModel.hydrateThreadPermissions(for: thread.key, appState: appState)
                ?? thread.key
            let nextKey = try await appModel.resumeThread(
                key: resumeKey,
                launchConfig: launchConfig(for: resumeKey),
                cwdOverride: thread.cwd
            )
            appModel.activateThread(nextKey)
            openedKey = nextKey
        } catch {
            actionErrorMessage = error.localizedDescription
            openedKey = nil
        }
        guard let openedKey else {
            actionErrorMessage = actionErrorMessage ?? "Failed to open conversation."
            return
        }
        openConversation(openedKey)
    }

    private func startNewSession(serverId: String, cwd: String) async {
        guard !isStartingNewSession else { return }
        let signpostID = OSSignpostID(log: homeNavigationSignpostLog)
        os_signpost(
            .begin,
            log: homeNavigationSignpostLog,
            name: "StartNewSession",
            signpostID: signpostID,
            "server=%{public}@ cwd=%{public}@",
            serverId,
            cwd
        )
        isStartingNewSession = true
        defer {
            isStartingNewSession = false
            os_signpost(.end, log: homeNavigationSignpostLog, name: "StartNewSession", signpostID: signpostID)
        }
        actionErrorMessage = nil
        let startedKey: ThreadKey
        do {
            guard try await appModel.ensureLocalAuthForThreadStart(serverId: serverId) else {
                return
            }
            await conversationWarmup.prewarmIfNeeded()
            workDir = cwd
            appState.currentCwd = cwd
            let key = try await appModel.client.startThread(
                serverId: serverId,
                params: launchConfig().threadStartRequest(
                    cwd: cwd,
                    dynamicTools: appModel.localGenerativeUiToolSpecs(for: serverId)
                )
            )
            startedKey = key
            RecentDirectoryStore.shared.record(path: cwd, for: serverId)
            homeDashboardModel.pinThread(key)
            appModel.store.setActiveThread(key: startedKey)
            await appModel.refreshThreadSnapshot(key: startedKey)
        } catch {
            actionErrorMessage = error.localizedDescription
            return
        }

        let resolvedKey = appModel.snapshot?.threadSnapshot(for: startedKey)?.key ?? startedKey
        openConversation(resolvedKey)
    }

    private func seedInitialConversationIfNeeded(activeKey: ThreadKey?) {
        guard !hasSeededInitialConversationRoute,
              !isStartingVoice,
              navigationPath.isEmpty,
              let activeKey else { return }

        Task { @MainActor in
            await conversationWarmup.prewarmIfNeeded()
            guard !hasSeededInitialConversationRoute,
                  !isStartingVoice,
                  navigationPath.isEmpty,
                  appModel.snapshot?.activeThread == activeKey else {
                return
            }
            hasSeededInitialConversationRoute = true
            navigationPath = [.conversation(activeKey)]
        }
    }

    private func launchConfig(for threadKey: ThreadKey? = nil) -> AppThreadLaunchConfig {
        let selectedModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSelectedModel = !selectedModel.isEmpty
        return AppThreadLaunchConfig(
            agentRuntimeKind: hasSelectedModel ? appState.selectedAgentRuntimeKind : nil,
            model: hasSelectedModel ? selectedModel : nil,
            approvalPolicy: appState.launchApprovalPolicy(for: threadKey),
            sandbox: appState.launchSandboxMode(for: threadKey),
            developerInstructions: nil,
            persistExtendedHistory: true
        )
    }

    private func voicePermissionConfig() async -> (
        approvalPolicy: AppAskForApproval?,
        sandboxMode: AppSandboxMode?
    ) {
        let storedThreadId = UserDefaults.standard.string(forKey: VoiceRuntimeController.persistedLocalVoiceThreadIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let threadKey = storedThreadId.flatMap { threadId -> ThreadKey? in
            guard !threadId.isEmpty else { return nil }
            return ThreadKey(serverId: VoiceRuntimeController.localServerID, threadId: threadId)
        }
        let resolvedThreadKey: ThreadKey?
        if let threadKey {
            resolvedThreadKey = await appModel.hydrateThreadPermissions(for: threadKey, appState: appState)
                ?? threadKey
        } else {
            resolvedThreadKey = nil
        }
        return (
            approvalPolicy: appState.launchApprovalPolicy(for: resolvedThreadKey),
            sandboxMode: appState.launchSandboxMode(for: resolvedThreadKey)
        )
    }

    private func openConversation(_ key: ThreadKey) {
        hasSeededInitialConversationRoute = true
        appState.showModelSelector = false
        guard navigationPath.last != .conversation(key) else { return }
        navigationPath.append(.conversation(key))
    }

    private func openRealtimeVoice(_ key: ThreadKey) {
        hasSeededInitialConversationRoute = true
        appState.showModelSelector = false
        guard navigationPath.last != .realtimeVoice(key) else { return }
        navigationPath.append(.realtimeVoice(key))
    }

    private func popToConversationInfo() {
        // Pop wallpaper selection and/or adjust screens, back to conversation info
        while let last = navigationPath.last {
            if case .conversationInfo = last { break }
            navigationPath.removeLast()
        }
    }

    private func popToServerInfo() {
        while let last = navigationPath.last {
            if case .serverInfo = last { break }
            navigationPath.removeLast()
        }
    }

    private func replaceTopConversation(with key: ThreadKey) {
        hasSeededInitialConversationRoute = true
        if case .conversation = navigationPath.last {
            navigationPath.removeLast()
        }
        openConversation(key)
    }

    /// Ambient hero-composer rendering for the split-view detail root. No
    /// auto-focus (so popping back from a conversation doesn't summon the
    /// keyboard) and no Cancel toolbar (there's nothing to cancel to at the
    /// root). On send it replaces itself with `.conversation(key)` via the
    /// same path as the pushed hero, so the handoff is identical.
    private var splitDetailRoot: some View {
        NewThreadHeroView(
            project: homeDashboardModel.selectedProject,
            connectedServers: homeDashboardModel.connectedServers,
            selectedServerId: homeDashboardModel.selectedServerId,
            onSelectServer: { serverId in
                homeDashboardModel.selectedServerId = serverId
            },
            onOpenProjectPicker: { showProjectPicker = true },
            onThreadCreated: { key in
                homeDashboardModel.pinThread(key)
                // Root is already the hero; just push the conversation on top.
                openConversation(key)
            },
            onCancel: nil,
            autoFocus: false
        )
    }

    /// Push the hero composer into the detail pane. On compact this pushes
    /// `.newThread` as a destination; on split it's a no-op because the
    /// detail root already *is* the hero view (just pop back to it).
    private func openNewThread() {
        if isEmbeddedInSplit {
            if !navigationPath.isEmpty {
                navigationPath.removeAll()
            }
            return
        }
        if case .newThread = navigationPath.last { return }
        if case .conversation = navigationPath.last {
            navigationPath.removeLast()
        }
        navigationPath.append(.newThread)
    }

    /// Swap the hero composer out for the freshly-created conversation in
    /// a single animation frame so the composer's apparent position is
    /// preserved by the glass morph.
    private func replaceHeroWithConversation(key: ThreadKey) {
        if case .newThread = navigationPath.last {
            navigationPath.removeLast()
        }
        openConversation(key)
    }

    private func popCurrentRoute() {
        guard !navigationPath.isEmpty else { return }
        appState.showModelSelector = false
        navigationPath.removeLast()
    }

    /// Sidebar projection of the home dashboard used inside
    /// `NavigationSplitView`. Same data + callbacks as `homeDashboard`, but
    /// renders with `.sidebar` chrome (no animated logo, no zoom, no bottom
    /// composer) and exposes an `onNewThread` hook that pushes the hero
    /// composer into the detail pane.
    private var sidebarDashboard: some View {
        HomeDashboardView(
            chrome: .sidebar,
            recentSessions: homeDashboardModel.recentSessions,
            allSessions: homeDashboardModel.allSessions,
            pinnedThreadKeys: homeDashboardModel.pinnedKeys,
            connectedServers: homeDashboardModel.connectedServers,
            projects: homeDashboardModel.projects,
            selectedServerId: homeDashboardModel.selectedServerId,
            selectedProject: homeDashboardModel.selectedProject,
            openingRecentSessionKey: openingRecentSessionKey,
            onOpenRecentSession: openRecentSession,
            onSelectServer: handleSelectServer,
            onAddServer: { appState.showServerPicker = true },
            onOpenProjectPicker: { showProjectPicker = true },
            onThreadCreated: { key in homeDashboardModel.pinThread(key) },
            onShowSettings: { appState.showSettings = true },
            onShowApps: savedAppsStore.apps.isEmpty ? nil : { navigationPath.append(.appsList) },
            onShowTerminal: terminalLauncher,
            onPinThread: pinThread,
            onUnpinThread: unpinThread,
            onHideThread: hideThread,
            onNewThread: { openNewThread() },
            onHydrateThread: { key, loadInitialTurns in
                await hydrateThread(key, loadInitialTurns: loadInitialTurns)
            },
            onDeleteThread: deleteThread,
            onReconnectServer: reconnectServer,
            onRestartAppServer: restartAppServer,
            onDisconnectServer: disconnectServer,
            onRenameServer: renameServer,
            onOpenRecording: { url in
                navigationPath.append(.replayRecording(url))
            },
            onSendReply: sendQuickReply,
            onCancelThread: cancelThread,
            onForkThread: forkSessionFromHome,
            onInputModeChange: { mode in
                homeInputMode = mode
            },
            onSearchThreads: loadSearchThreads
        )
    }

    private var homeDashboard: some View {
        HomeDashboardView(
            recentSessions: homeDashboardModel.recentSessions,
            allSessions: homeDashboardModel.allSessions,
            pinnedThreadKeys: homeDashboardModel.pinnedKeys,
            connectedServers: homeDashboardModel.connectedServers,
            projects: homeDashboardModel.projects,
            selectedServerId: homeDashboardModel.selectedServerId,
            selectedProject: homeDashboardModel.selectedProject,
            openingRecentSessionKey: openingRecentSessionKey,
            onOpenRecentSession: openRecentSession,
            onSelectServer: handleSelectServer,
            onAddServer: { appState.showServerPicker = true },
            onOpenProjectPicker: { showProjectPicker = true },
            onThreadCreated: { key in homeDashboardModel.pinThread(key); openConversation(key) },
            onShowSettings: { appState.showSettings = true },
            onShowApps: savedAppsStore.apps.isEmpty ? nil : { navigationPath.append(.appsList) },
            onShowTerminal: terminalLauncher,
            onPinThread: pinThread,
            onUnpinThread: unpinThread,
            onHideThread: hideThread,
            onHydrateThread: { key, loadInitialTurns in
                await hydrateThread(key, loadInitialTurns: loadInitialTurns)
            },
            onDeleteThread: deleteThread,
            onReconnectServer: reconnectServer,
            onRestartAppServer: restartAppServer,
            onDisconnectServer: disconnectServer,
            onRenameServer: renameServer,
            onOpenRecording: { url in
                navigationPath.append(.replayRecording(url))
            },
            onSendReply: sendQuickReply,
            onCancelThread: cancelThread,
            onForkThread: forkSessionFromHome,
            onInputModeChange: { mode in
                homeInputMode = mode
            },
            onSearchThreads: loadSearchThreads
        )
    }

    private func handleSelectServer(_ server: HomeDashboardServer) {
        guard server.canLaunchSessions else {
            reconnectServer(server)
            return
        }
        if homeDashboardModel.selectedServerId == server.id {
            homeDashboardModel.clearScope()
        } else {
            homeDashboardModel.selectedServerId = server.id
        }
    }

    private func pinThread(_ key: ThreadKey) {
        let shouldUnsubscribeDisplacedRecent = homeDashboardModel.pinnedKeys.isEmpty
        let displacedKeys = shouldUnsubscribeDisplacedRecent
            ? Set(homeDashboardModel.recentSessions.map(\.key)).subtracting([key])
            : []
        homeDashboardModel.pinThread(key)
        unsubscribeHomeThreads(Array(displacedKeys))
    }

    private func unpinThread(_ key: ThreadKey) {
        homeDashboardModel.unpinThread(key)
    }

    private func hideThread(_ key: ThreadKey) {
        homeDashboardModel.hideThread(key)
        unsubscribeHomeThreads([key])
    }

    private func unsubscribeHomeThreads(_ keys: [ThreadKey]) {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return }
        Task {
            for key in uniqueKeys {
                do {
                    try await appModel.store.unsubscribeThread(key: key)
                } catch {
                    LLog.warn(
                        "transport",
                        "failed to unsubscribe hidden/displaced home thread",
                        fields: [
                            "serverId": key.serverId,
                            "threadId": key.threadId,
                            "error": String(describing: error)
                        ]
                    )
                }
            }
        }
    }

    private func homeHydrationId(_ key: ThreadKey) -> String {
        "\(key.serverId)/\(key.threadId)"
    }

    private func hydratePinnedThreadsIfNeeded() {
        let connectedServerIds = Set(
            (appModel.snapshot?.servers ?? [])
                .filter(\.isConnected)
                .map(\.serverId)
        )
        guard !connectedServerIds.isEmpty else { return }

        for pin in homeDashboardModel.pinnedKeys {
            let key = pin.threadKey
            guard connectedServerIds.contains(key.serverId) else { continue }
            let id = homeHydrationId(key)
            if appModel.snapshot?.sessionSummary(for: key)?.isResumed == true { continue }
            guard !hydratingPinnedHomeThreadIds.contains(id) else { continue }
            hydratingPinnedHomeThreadIds.insert(id)

            Task {
                LLog.info(
                    "home",
                    "hydrating pinned thread",
                    fields: ["serverId": key.serverId, "threadId": key.threadId]
                )
                if !(await hydrateThread(key, loadInitialTurns: true)) {
                    let refreshed = await refreshPinnedThreadListing(serverId: key.serverId)
                    guard refreshed else {
                        await MainActor.run {
                            _ = hydratingPinnedHomeThreadIds.remove(id)
                        }
                        return
                    }
                    _ = await hydrateThread(key, loadInitialTurns: true)
                }
                await MainActor.run {
                    _ = hydratingPinnedHomeThreadIds.remove(id)
                }
            }
        }
    }

    @discardableResult
    private func hydrateThread(_ key: ThreadKey, loadInitialTurns: Bool) async -> Bool {
        // Resume rather than just read: `external_resume_thread` attaches a
        // server-side conversation listener for this connection, so we get
        // live `TurnStarted` / `ItemStarted` / `MessageDelta` /
        // `TurnCompleted` events. Pinned home rows also load the latest turn
        // window so their previews have recent message content.
        //
        // For pinned home rows, resuming preemptively avoids the "first
        // half-second of a stream is missed while we set up a subscription"
        // latency window that an active-only subscription strategy would
        // have. `externalResume` short-circuits to a no-op when the thread's
        // items are already populated, so warm paths are cheap.
        let resumed = (try? await appModel.store.externalResumeThread(key: key, hostId: nil)) != nil
        if resumed, loadInitialTurns {
            await appModel.loadInitialTurnsIfNeeded(threadId: key)
        }
        await appModel.refreshThreadSnapshot(key: key)
        return resumed
    }

    private func refreshPinnedThreadListing(serverId: String) async -> Bool {
        let task = await MainActor.run {
            if let existing = pinnedThreadListingRepairTasks[serverId] {
                return existing
            }

            let task = Task { () -> Bool in
                LLog.info(
                    "home",
                    "repairing pinned thread listing",
                    fields: ["serverId": serverId, "limit": 80]
                )
                do {
                    try await appModel.client.listThreads(
                        serverId: serverId,
                        params: AppListThreadsRequest(
                            cursor: nil,
                            limit: 80,
                            sortKey: .updatedAt,
                            sortDirection: .desc,
                            modelProviders: nil,
                            sourceKinds: [.cli, .vsCode, .appServer],
                            archived: false,
                            cwd: nil,
                            searchTerm: nil,
                            useStateDbOnly: false,
                            runtimeKinds: nil
                        )
                    )
                    return true
                } catch {
                    LLog.warn(
                        "home",
                        "pinned thread listing repair failed",
                        fields: ["serverId": serverId, "error": String(describing: error)]
                    )
                    return false
                }
            }
            pinnedThreadListingRepairTasks[serverId] = task
            return task
        }

        let refreshed = await task.value
        await MainActor.run {
            pinnedThreadListingRepairTasks[serverId] = nil
        }
        return refreshed
    }

    private func deleteThread(_ key: ThreadKey) async {
        _ = try? await appModel.client.archiveThread(
            serverId: key.serverId,
            params: AppArchiveThreadRequest(threadId: key.threadId)
        )
        await appModel.refreshThreadSnapshot(key: key)
    }

    /// Long-press → "Fork" on a home session card. Head-of-thread fork:
    /// duplicates the full thread server-side (no rollback) and navigates
    /// to the new copy. Mirrors `ConversationInfoView.forkConversation`.
    @MainActor
    private func forkSessionFromHome(_ session: HomeDashboardRecentSession) async {
        let threadKey = session.key
        do {
            let sourceKey = await appModel.hydrateThreadPermissions(for: threadKey, appState: appState) ?? threadKey
            let source = appModel.snapshot?.threadSnapshot(for: sourceKey)
            let newKey = try await appModel.client.forkThread(
                serverId: sourceKey.serverId,
                params: AppThreadLaunchConfig(
                    model: source?.model,
                    approvalPolicy: appState.launchApprovalPolicy(for: sourceKey),
                    sandbox: appState.launchSandboxMode(for: sourceKey),
                    developerInstructions: nil,
                    persistExtendedHistory: true
                ).threadForkRequest(threadId: sourceKey.threadId, cwdOverride: source?.info.cwd)
            )
            appModel.store.setActiveThread(key: newKey)
            await appModel.refreshThreadSnapshot(key: newKey)
            openConversation(newKey)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func cancelThread(_ threadKey: ThreadKey) async {
        // Look up the thread's active turn id — interrupt requires both.
        guard let thread = appModel.snapshot?.threadSnapshot(for: threadKey),
              let turnId = thread.activeTurnId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !turnId.isEmpty else {
            return
        }
        do {
            _ = try await appModel.client.interruptTurn(
                serverId: threadKey.serverId,
                params: AppInterruptTurnRequest(
                    threadId: threadKey.threadId,
                    turnId: turnId
                )
            )
            await appModel.refreshThreadSnapshot(key: threadKey)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func sendQuickReply(_ threadKey: ThreadKey, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The server needs the thread resumed before `startTurn` can find
        // it — same path `openRecentSession` takes. On a cold launch the
        // thread is in hydrated snapshot state but not yet registered with
        // the upstream session, so a quick-reply without resume would fail
        // with "thread cannot be found".
        let resumeKey = await appModel.hydrateThreadPermissions(for: threadKey, appState: appState)
            ?? threadKey
        let activeKey: ThreadKey
        do {
            activeKey = try await appModel.resumeThread(
                key: resumeKey,
                launchConfig: launchConfig(for: resumeKey),
                cwdOverride: nil
            )
        } catch {
            actionErrorMessage = error.localizedDescription
            return
        }
        let payload = AppComposerPayload(
            text: trimmed,
            additionalInputs: [],
            approvalPolicy: appState.launchApprovalPolicy(for: activeKey),
            sandboxPolicy: appState.turnSandboxPolicy(for: activeKey),
            model: nil,
            effort: nil,
            serviceTier: nil
        )
        do {
            try await appModel.startTurn(key: activeKey, payload: payload)
            await appModel.refreshThreadSnapshot(key: activeKey)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func reconnectServer(_ server: HomeDashboardServer) {
        Task {
            await AppRuntimeController.shared.reconnectServer(serverId: server.id)
        }
    }

    private func restartAppServer(_ server: HomeDashboardServer) {
        Task {
            do {
                if server.isLocal {
                    try await appModel.restartLocalServer()
                } else {
                    try await appModel.serverBridge.restartAppServer(serverId: server.id)
                    await AppRuntimeController.shared.reconnectServer(serverId: server.id)
                }
                await appModel.refreshSnapshot()
            } catch {
                actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func disconnectServer(_ serverId: String) {
        SavedServerStore.remove(serverId: serverId)
        Task { await SshSessionStore.shared.close(serverId: serverId, ssh: appModel.ssh) }
        // Remote transport resources are owned by the Rust `ServerSession` and
        // dropped automatically inside `serverBridge.disconnectServer`.
        appModel.serverBridge.disconnectServer(serverId: serverId)
    }

    private func renameServer(_ serverId: String, newName: String) {
        SavedServerStore.rename(serverId: serverId, newName: newName)
        appModel.reconnectController.setMultiClankerAndQuicEnabled(enabled: true)
        appModel.reconnectController.syncSavedServers(
            servers: SavedServerStore.reconnectRecords(
                localDisplayName: appModel.resolvedLocalServerDisplayName()
            )
        )
        appModel.store.renameServer(serverId: serverId, displayName: newName)
    }

    @Sendable
    private func loadSearchThreads(
        query: String,
        runtimeKind: AgentRuntimeKind?,
        serverId selectedServerId: String?,
        forceRepair: Bool
    ) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceKinds: [AppThreadSourceKind] = [.cli, .vsCode, .appServer]
        let selectedServerFilterId = selectedServerId?.trimmingCharacters(in: .whitespacesAndNewlines)
        await withTaskGroup(of: Void.self) { group in
            for server in homeDashboardModel.connectedServers {
                if let selectedServerFilterId, !selectedServerFilterId.isEmpty, server.id != selectedServerFilterId {
                    continue
                }
                if let runtimeKind,
                   !server.agentRuntimes.contains(where: { $0.available && $0.kind == runtimeKind }) {
                    continue
                }
                let serverId = server.id
                group.addTask {
                    _ = try? await appModel.client.listThreads(
                        serverId: serverId,
                        params: AppListThreadsRequest(
                            cursor: nil,
                            limit: 80,
                            sortKey: .updatedAt,
                            sortDirection: .desc,
                            modelProviders: nil,
                            sourceKinds: sourceKinds,
                            archived: false,
                            cwd: nil,
                            searchTerm: trimmedQuery.isEmpty ? nil : trimmedQuery,
                            useStateDbOnly: !forceRepair,
                            runtimeKinds: runtimeKind.map { [$0] }
                        )
                    )
                }
            }
        }
    }

    private func updateHomeDashboardActivity() {
        if isHomeRouteActive {
            homeDashboardModel.activate()
        } else {
            homeDashboardModel.deactivate()
        }
    }

    private func showSessions(for serverId: String) {
        appState.sessionsSelectedServerFilterId = serverId
        appState.sessionsShowOnlyForks = false
        appState.showModelSelector = false
        hasSeededInitialConversationRoute = true

        if let existingIndex = navigationPath.lastIndex(where: { route in
            guard case let .sessions(id, _) = route else { return false }
            return id == serverId
        }) {
            navigationPath = Array(navigationPath.prefix(through: existingIndex))
            return
        }

        if case .conversation = navigationPath.last {
            navigationPath.removeLast()
        } else if case .realtimeVoice = navigationPath.last {
            navigationPath.removeLast()
        }
        navigationPath.append(.sessions(serverId: serverId, title: serverTitle(for: serverId)))
    }

    private func serverTitle(for serverId: String) -> String {
        if let server = homeDashboardModel.connectedServers.first(where: { $0.id == serverId }) {
            return server.displayName
        }
        if let thread = homeDashboardModel.recentSessions.first(where: { $0.serverId == serverId }) {
            return thread.serverDisplayName
        }
        return "Sessions"
    }
}

private struct ConversationDestinationScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var screenModel = ConversationScreenModel()
    let threadKey: ThreadKey
    let bottomInset: CGFloat
    let onResumeSessions: (String) -> Void
    let onOpenConversation: (ThreadKey) -> Void
    var onInfo: (() -> Void)?

    private var conversationThread: AppThreadSnapshot? {
        appModel.threadSnapshot(for: threadKey)
    }

    private var resolvedThreadKey: ThreadKey {
        conversationThread?.key ?? threadKey
    }

    private var pendingUserInputsForThread: [PendingUserInputRequest] {
        guard let snapshot = appModel.snapshot else { return [] }
        let key = resolvedThreadKey
        return snapshot.pendingUserInputs.filter {
            $0.isRelevant(to: key)
        }
    }

    private var relevantServerSnapshot: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: resolvedThreadKey.serverId)
    }

    private func bindScreenModel(for thread: AppThreadSnapshot) {
        screenModel.bind(
            thread: thread,
            appModel: appModel,
            agentDirectoryVersion: appModel.snapshot?.agentDirectoryVersion ?? 0
        )
    }

    private var navigationTitle: String {
        conversationThread?.displayTitle ?? "Conversation"
    }

    var body: some View {
        Group {
            if let conversationThread {
                @Bindable var bindableScreenModel = screenModel
                ConversationView(
                    thread: conversationThread,
                    activeThreadKey: resolvedThreadKey,
                    transcript: screenModel.transcript,
                    followScrollToken: screenModel.followScrollToken,
                    pinnedContextItems: screenModel.pinnedContextItems,
                    composer: screenModel.composer,
                    composerInputText: $bindableScreenModel.composerInputText,
                    composerAttachedImage: $bindableScreenModel.composerAttachedImage,
                    topInset: 0,
                    bottomInset: bottomInset,
                    onOpenConversation: onOpenConversation,
                    onResumeSessions: onResumeSessions,
                    minigameOverlay: screenModel.minigameOverlay,
                    onTypingTap: { screenModel.requestMinigame() },
                    onMinigameDismiss: { screenModel.dismissMinigame() },
                    onMinigameRetry: {
                        screenModel.dismissMinigame()
                        screenModel.requestMinigame()
                    }
                )
                .onAppear {
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: conversationThread) { _, updatedThread in
                    bindScreenModel(for: updatedThread)
                }
                .onChange(of: appModel.snapshotRevision) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: pendingUserInputsForThread) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: relevantServerSnapshot) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: appModel.composerPrefillRequest) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .tint(LitterTheme.accent)
                    Text("Loading thread...")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let conversationThread {
                ToolbarItem(placement: .principal) {
                    HeaderView(thread: conversationThread)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ConversationToolbarControls(
                        thread: conversationThread,
                        control: .reload
                    )
                }
                if onInfo != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        ConversationToolbarControls(
                            thread: conversationThread,
                            control: .info,
                            onInfo: onInfo
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .task(id: threadKey) {
            os_signpost(
                .event,
                log: conversationRouteSignpostLog,
                name: "ThreadOpenStarted",
                "server=%{public}@ thread=%{public}@",
                threadKey.serverId,
                threadKey.threadId
            )
            appModel.activateThread(threadKey)
            if appModel.threadSnapshot(for: threadKey) == nil {
                _ = await appModel.ensureThreadLoaded(key: threadKey)
            }
            await appModel.loadConversationMetadataIfNeeded(serverId: threadKey.serverId)
            if let thread = conversationThread,
               let cwd = thread.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cwd.isEmpty {
                workDir = cwd
                appState.currentCwd = cwd
            }
        }
    }
}

private struct ReplayDestinationScreen: View {
    @Environment(AppModel.self) private var appModel
    let recordingUrl: URL
    let bottomInset: CGFloat
    @State private var screenModel = ConversationScreenModel()
    @State private var replayThreadKey: ThreadKey?
    @State private var recorder = MessageRecorder.shared

    private var conversationThread: AppThreadSnapshot? {
        guard let key = replayThreadKey else { return nil }
        return appModel.threadSnapshot(for: key)
    }

    var body: some View {
        Group {
            if let thread = conversationThread, let key = replayThreadKey {
                @Bindable var bindableScreenModel = screenModel
                ConversationView(
                    thread: thread,
                    activeThreadKey: key,
                    transcript: screenModel.transcript,
                    followScrollToken: screenModel.followScrollToken,
                    pinnedContextItems: screenModel.pinnedContextItems,
                    composer: screenModel.composer,
                    composerInputText: $bindableScreenModel.composerInputText,
                    composerAttachedImage: $bindableScreenModel.composerAttachedImage,
                    topInset: 0,
                    bottomInset: bottomInset,
                    onOpenConversation: nil,
                    onResumeSessions: { _ in }
                )
                .onAppear { bindScreenModel(for: thread) }
                .onChange(of: thread) { _, t in bindScreenModel(for: t) }
                .onChange(of: appModel.snapshotRevision) { _, _ in
                    if let t = conversationThread { bindScreenModel(for: t) }
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .tint(LitterTheme.accent)
                    Text(recorder.isReplaying ? "Replaying..." : "Starting replay...")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            }
        }
        .navigationTitle("Replay")
        .navigationBarTitleDisplayMode(.inline)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .task {
            let targetKey: ThreadKey
            if let server = appModel.snapshot?.servers.first {
                targetKey = ThreadKey(serverId: server.serverId, threadId: UUID().uuidString)
            } else {
                targetKey = ThreadKey(serverId: "replay", threadId: UUID().uuidString)
            }
            replayThreadKey = targetKey
            appModel.activateThread(targetKey)
            recorder.startReplay(url: recordingUrl, store: appModel.store, targetKey: targetKey)
        }
        .onDisappear {
            recorder.stopReplay()
        }
    }

    private func bindScreenModel(for thread: AppThreadSnapshot) {
        screenModel.bind(
            thread: thread,
            appModel: appModel,
            agentDirectoryVersion: appModel.snapshot?.agentDirectoryVersion ?? 0
        )
    }
}

private struct ApprovalPromptView: View {
    let approval: PendingApproval
    let onDecision: (ApprovalDecisionValue) -> Void
    var onViewThread: ((ThreadKey) -> Void)? = nil

    private var title: String {
        switch approval.kind {
        case .command:
            return "Command Approval Required"
        case .fileChange:
            return "File Change Approval Required"
        case .permissions:
            return "Permissions Approval Required"
        case .mcpElicitation:
            return "MCP Input Required"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .litterFont(.headline)
                    .foregroundColor(LitterTheme.textPrimary)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let reason = approval.reason, !reason.isEmpty {
                            Text(reason)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textSecondary)
                        }

                        if let threadId = approval.threadId, onViewThread != nil {
                            HStack {
                                Button {
                                    onViewThread?(ThreadKey(serverId: approval.serverId, threadId: threadId))
                                } label: {
                                    HStack(spacing: 3) {
                                        Text("View Thread")
                                            .litterFont(.caption, weight: .medium)
                                        Image(systemName: "arrow.right")
                                            .litterFont(size: 9, weight: .semibold)
                                    }
                                    .foregroundColor(LitterTheme.accent)
                                }
                                .buttonStyle(.plain)

                                Spacer()
                            }
                        }

                        if let command = approval.command, !command.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Command")
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textMuted)
                                Text(command)
                                    .litterFont(.footnote)
                                    .foregroundColor(LitterTheme.textBody)
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(LitterTheme.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        if let cwd = approval.cwd, !cwd.isEmpty {
                            Text("CWD: \(cwd)")
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textMuted)
                        }

                        if let grantRoot = approval.grantRoot, !grantRoot.isEmpty {
                            Text("Grant Root: \(grantRoot)")
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 8) {
                    Button("Allow Once") { onDecision(.accept) }
                        .buttonStyle(.borderedProminent)
                        .tint(LitterTheme.accent)
                        .frame(maxWidth: .infinity)

                    Button("Allow for Session") { onDecision(.acceptForSession) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                    HStack(spacing: 8) {
                        Button("Deny") { onDecision(.decline) }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)

                        Button("Abort") { onDecision(.cancel) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
                .litterFont(.callout)
            }
            .padding(16)
            .frame(maxHeight: UIScreen.main.bounds.height * 0.8)
            .modifier(GlassRectModifier(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(LitterTheme.border, lineWidth: 1)
            )
            .padding(.horizontal, 16)
        }
        .transition(.opacity)
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 24) {
                BrandLogo(size: 132)
                Text("AI coding agent on iOS")
                    .litterFont(.body)
                    .foregroundColor(LitterTheme.textMuted)
            }
        }
    }
}
