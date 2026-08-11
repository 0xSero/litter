import CarPlay
import UIKit
import os

@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private static let log = Logger(subsystem: "com.sigkitten.litter", category: "CarPlay")

    private var interfaceController: CPInterfaceController?
    private var voiceManager: CarPlayVoiceManager?

    // MARK: - Scene Lifecycle

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        Self.log.info("CarPlay scene willConnect role=\(session.role.rawValue, privacy: .public)")
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Self.log.info("CarPlay didConnect interfaceController")
        self.interfaceController = interfaceController

        // Set a minimal root template first so the watchdog is satisfied
        // (CarPlay kills the scene if no root template is set quickly).
        let placeholder = CPGridTemplate(title: "Litter", gridButtons: [Self.placeholderButton()])
        placeholder.tabImage = UIImage(systemName: "waveform")
        placeholder.tabTitle = "Voice"
        interfaceController.setRootTemplate(placeholder, animated: false) { success, error in
            if success {
                Self.log.info("CarPlay placeholder root set")
            } else {
                let message = error?.localizedDescription ?? "unknown error"
                Self.log.error("CarPlay failed to set placeholder root: \(message, privacy: .public)")
            }
        }

        // Build the real templates asynchronously so any slow init in
        // AppModel.shared / VoiceRuntimeController.shared can't block the
        // scene-connect watchdog.
        Task { @MainActor [weak self] in
            guard let self, let ic = self.interfaceController else { return }
            let vm = CarPlayVoiceManager(
                voiceActions: VoiceRuntimeController.shared,
                appModel: AppModel.shared,
                interfaceController: ic
            )
            self.voiceManager = vm
            let tabBar = CPTabBarTemplate(templates: [
                vm.buildVoiceTab(),
                vm.buildSessionsTab()
            ])
            ic.setRootTemplate(tabBar, animated: false) { success, error in
                if success {
                    Self.log.info("CarPlay tab bar root installed")
                } else {
                    let message = error?.localizedDescription ?? "unknown error"
                    Self.log.error("CarPlay failed to set tab bar root: \(message, privacy: .public)")
                }
            }
            vm.startObserving()
        }
    }

    private static func placeholderButton() -> CPGridButton {
        let image = UIImage(systemName: "waveform",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .semibold))
            ?? UIImage()
        return CPGridButton(titleVariants: ["Loading…"], image: image) { _ in }
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Self.log.info("CarPlay didDisconnect")
        voiceManager?.stopObserving()
        voiceManager = nil
        self.interfaceController = nil
    }
}
