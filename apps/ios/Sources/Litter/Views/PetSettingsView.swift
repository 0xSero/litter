import SwiftUI

struct PetSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var controller = PetOverlayController.shared
    @State private var selectedServerId = ""
    @State private var pets: [AppPetSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Mirrored out of `appModel.snapshot` by `snapshotObserver`. Reading
    /// `appModel.snapshot` from `body` re-rendered this Form at the ~8 fps
    /// streaming snapshot cadence.
    @State private var connectedServers: [AppServerSnapshot] = []
    @State private var snapshotObserver = AppSnapshotObserver()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { controller.visible },
                    set: { controller.setVisible($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Pet")
                            .litterFont(.subheadline)
                            .foregroundColor(LitterTheme.textPrimary)
                        Text(controller.selectedPet?.displayName ?? "No pet selected")
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
                .tint(LitterTheme.accent)
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            } header: {
                Text("Wake")
                    .foregroundColor(LitterTheme.textSecondary)
            }

            Section {
                if connectedServers.isEmpty {
                    Text("Connect to a server first")
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textMuted)
                } else {
                    ForEach(connectedServers, id: \.serverId) { server in
                        Button {
                            selectedServerId = server.serverId
                            Task { await refreshPets() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.displayName)
                                        .litterFont(.subheadline)
                                        .foregroundColor(LitterTheme.textPrimary)
                                    Text(server.connectionModeLabel)
                                        .litterFont(.caption)
                                        .foregroundColor(LitterTheme.textSecondary)
                                }
                                Spacer()
                                if server.serverId == selectedServerId {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(LitterTheme.accentStrong)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Server")
                    .foregroundColor(LitterTheme.textSecondary)
            }

            Section {
                if selectedServerId.isEmpty {
                    Text("No server selected")
                        .foregroundColor(LitterTheme.textMuted)
                } else if isLoading {
                    HStack {
                        ProgressView().tint(LitterTheme.accent)
                        Text("Loading pets")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(LitterTheme.danger)
                } else if pets.isEmpty {
                    Text("~/.codex/pets has no hatch-pet packages")
                        .foregroundColor(LitterTheme.textMuted)
                } else {
                    ForEach(pets, id: \.id) { pet in
                        Button {
                            guard pet.hasValidSpritesheet else { return }
                            Task {
                                await controller.selectPet(
                                    appModel: appModel,
                                    serverId: selectedServerId,
                                    pet: pet
                                )
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pet.displayName)
                                        .litterFont(.subheadline)
                                        .foregroundColor(pet.hasValidSpritesheet ? LitterTheme.textPrimary : LitterTheme.textMuted)
                                    Text(pet.validationError ?? pet.description ?? pet.sourcePath)
                                        .litterFont(.caption)
                                        .foregroundColor(LitterTheme.textSecondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                if controller.isLoading,
                                   controller.selectedPet?.id == pet.id,
                                   controller.selectedPet?.serverId == selectedServerId {
                                    ProgressView().tint(LitterTheme.accent)
                                } else if controller.selectedPet?.id == pet.id,
                                          controller.selectedPet?.serverId == selectedServerId {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(LitterTheme.accentStrong)
                                }
                            }
                        }
                        .disabled(!pet.hasValidSpritesheet)
                    }
                }

                if let message = controller.errorMessage {
                    Text(message)
                        .foregroundColor(LitterTheme.danger)
                }
            } header: {
                HStack {
                    Text("Pets")
                    Spacer()
                    Button("Refresh") {
                        Task { await refreshPets() }
                    }
                    .disabled(selectedServerId.isEmpty || isLoading)
                }
                .foregroundColor(LitterTheme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(LitterTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Pet")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Keeps `connectedServers` live: the observer re-runs the
            // projection on every (coalesced) snapshot revision, so servers
            // connecting/disconnecting while this screen is open still show up.
            let model = appModel
            snapshotObserver.start(appModel: model) { refreshConnectedServers(model) }
            if selectedServerId.isEmpty {
                selectedServerId = controller.selectedPet?.serverId
                    ?? appModel.snapshot?.activeThread?.serverId
                    ?? connectedServers.first?.serverId
                    ?? ""
            }
            await refreshPets()
        }
        .onDisappear { snapshotObserver.stop() }
    }

    /// Called from `snapshotObserver`, never from `body`. Writes `@State` only
    /// on a real change so idle snapshot bumps cost nothing. Takes the model
    /// explicitly so the deferred closure never reads `@Environment`.
    private func refreshConnectedServers(_ appModel: AppModel) {
        let next = appModel.snapshot?.servers.filter(\.isConnected) ?? []
        if connectedServers != next {
            connectedServers = next
        }
    }

    @MainActor
    private func refreshPets() async {
        guard !selectedServerId.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            pets = try await appModel.client.listPets(serverId: selectedServerId)
        } catch {
            pets = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
