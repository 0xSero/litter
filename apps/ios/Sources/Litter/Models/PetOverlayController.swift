import Foundation
import Observation
import SwiftUI

enum PetAvatarState: Int {
    case idle = 0
    case runningRight = 1
    case runningLeft = 2
    case waving = 3
    case jumping = 4
    case failed = 5
    case waiting = 6
    case running = 7
    case review = 8
}

struct CachedPetPackage: Equatable {
    let serverId: String
    let id: String
    let displayName: String
    let spritesheetBytes: Data
}

@MainActor
@Observable
final class PetOverlayController {
    static let shared = PetOverlayController()

    private let visibleKey = "litter.petOverlay.visible"
    private let serverIdKey = "litter.petOverlay.serverId"
    private let petIdKey = "litter.petOverlay.petId"
    private let petNameKey = "litter.petOverlay.petName"

    private(set) var visible = false
    private(set) var selectedPet: CachedPetPackage?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var dragOffset = CGSize(width: 24, height: 96)
    private(set) var isDragging = false
    private var dragDirection = PetAvatarState.runningRight

    private init() {
        visible = UserDefaults.standard.bool(forKey: visibleKey)
        guard let serverId = UserDefaults.standard.string(forKey: serverIdKey),
              let petId = UserDefaults.standard.string(forKey: petIdKey),
              let name = UserDefaults.standard.string(forKey: petNameKey),
              let data = try? Data(contentsOf: cacheURL(serverId: serverId, petId: petId))
        else { return }
        selectedPet = CachedPetPackage(
            serverId: serverId,
            id: petId,
            displayName: name,
            spritesheetBytes: data
        )
    }

    func setVisible(_ next: Bool) {
        visible = next
        UserDefaults.standard.set(next, forKey: visibleKey)
    }

    func selectPet(appModel: AppModel, serverId: String, pet: AppPetSummary) async {
        isLoading = true
        errorMessage = nil
        do {
            let package = try await appModel.client.loadPet(serverId: serverId, petId: pet.id)
            let cached = CachedPetPackage(
                serverId: serverId,
                id: package.summary.id,
                displayName: package.summary.displayName,
                spritesheetBytes: Data(package.spritesheetBytes)
            )
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try cached.spritesheetBytes.write(to: cacheURL(serverId: serverId, petId: cached.id))
            UserDefaults.standard.set(serverId, forKey: serverIdKey)
            UserDefaults.standard.set(cached.id, forKey: petIdKey)
            UserDefaults.standard.set(cached.displayName, forKey: petNameKey)
            UserDefaults.standard.set(true, forKey: visibleKey)
            selectedPet = cached
            visible = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func startDrag() {
        isDragging = true
    }

    func dragBy(_ translation: CGSize) {
        dragOffset.width += translation.width
        dragOffset.height += translation.height
        if translation.width > 0.5 { dragDirection = .runningRight }
        if translation.width < -0.5 { dragDirection = .runningLeft }
    }

    func endDrag() {
        isDragging = false
    }

    func avatarState(snapshot: AppSnapshotRecord?) -> PetAvatarState {
        if isLoading { return .waiting }
        if isDragging { return dragDirection }
        guard let snapshot else { return .idle }
        if !snapshot.pendingApprovals.isEmpty || !snapshot.pendingUserInputs.isEmpty {
            return .review
        }
        let activeThread = snapshot.activeThread.flatMap { key in
            snapshot.threads.first(where: { $0.key == key })
        }
        if activeThread?.info.status == .systemError { return .failed }
        if activeThread?.hasActiveTurn == true { return .running }
        if snapshot.threads.contains(where: { $0.info.status == .systemError }) {
            return .failed
        }
        return snapshot.servers.contains(where: \.isConnected) ? .idle : .waiting
    }

    func avatarMessage(snapshot: AppSnapshotRecord?) -> String? {
        if isLoading { return "Fetching pet..." }
        if isDragging { return nil }
        guard let snapshot else { return nil }
        if !snapshot.pendingApprovals.isEmpty { return "Review needed" }
        if !snapshot.pendingUserInputs.isEmpty { return "Input needed" }
        let activeThread = snapshot.activeThread.flatMap { key in
            snapshot.threads.first(where: { $0.key == key })
        }
        if activeThread?.info.status == .systemError { return "Run failed" }
        if activeThread?.hasActiveTurn == true { return "Working..." }
        if snapshot.threads.contains(where: { $0.info.status == .systemError }) {
            return "Thread failed"
        }
        return snapshot.servers.contains(where: \.isConnected) ? nil : "Waiting for server"
    }

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Pets", isDirectory: true)
    }

    private func cacheURL(serverId: String, petId: String) -> URL {
        cacheDirectory.appendingPathComponent("\(safe(serverId))_\(safe(petId)).webp")
    }

    private func safe(_ value: String) -> String {
        value.map { char in
            char.isLetter || char.isNumber || char == "-" || char == "_" || char == "." ? char : "_"
        }.map(String.init).joined()
    }
}
