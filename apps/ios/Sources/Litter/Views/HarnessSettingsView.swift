import SwiftUI

struct HarnessSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var targets: [Target] = []
    @State private var observer = AppSnapshotObserver()

    private struct Target: Identifiable, Equatable {
        let id: String
        let name: String
        let runtimes: [String]
    }

    var body: some View {
        List {
            if targets.isEmpty {
                Text("Connect to a server to configure its harnesses.")
                    .foregroundStyle(LitterTheme.textSecondary)
            }
            ForEach(targets) { target in
                Section(target.name) {
                    ForEach(target.runtimes, id: \.self) { runtime in
                        NavigationLink {
                            RuntimeSettingsView(serverId: target.id, runtime: runtime)
                        } label: {
                            Text(runtime.displayLabel)
                        }
                        .accessibilityIdentifier("harness.runtime.\(target.id).\(runtime)")
                    }
                }
                .listRowBackground(LitterTheme.surface)
            }
        }
        .litterFont(.body)
        .foregroundStyle(LitterTheme.textPrimary)
        .scrollContentBackground(.hidden)
        .background(LitterTheme.backgroundGradient)
        .navigationTitle("Harnesses")
        .task {
            #if DEBUG
            if HarnessSettingsUITestFixture.isEnabled {
                targets = [Target(id: "ui-test-settings-server", name: "UI Test Server", runtimes: ["pi"])]
                return
            }
            #endif
            observer.start(appModel: appModel) {
                let next = (appModel.snapshot?.servers ?? []).filter(\.isConnected).map { server in
                    Target(id: server.serverId, name: server.displayName,
                           runtimes: server.agentRuntimes.filter(\.available).map(\.kind).sorted())
                }.sorted { $0.id < $1.id }
                if next != targets { targets = next }
            }
        }
        .onDisappear { observer.stop() }
    }
}

private struct RuntimeSettingsView: View {
    @Environment(AppModel.self) private var appModel
    let serverId: String
    let runtime: String
    @State private var settings: [RuntimeSettingDescriptor] = []
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var editing: RuntimeSettingDescriptor?

    var body: some View {
        List {
            Section {
                Text("Native harness settings. Saved values take effect when the harness reloads its configuration or starts a new session.")
                    .litterFont(.footnote)
                    .foregroundStyle(LitterTheme.textSecondary)
            }
            if loading { ProgressView() }
            if let error {
                Section {
                    Text(error).foregroundStyle(LitterTheme.danger)
                    Button("Retry") { Task { await load() } }
                }
            }
            if !loading && error == nil && settings.isEmpty {
                Text("This harness does not expose settings for this connection.")
            }
            ForEach(settings.filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) || $0.label.localizedCaseInsensitiveContains(search) }, id: \.key) { setting in
                Button { editing = setting } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(setting.label).foregroundStyle(LitterTheme.textPrimary)
                        Text(setting.valueJson).lineLimit(2)
                            .litterFont(.caption).foregroundStyle(LitterTheme.textSecondary)
                        if let reason = setting.readOnlyReason {
                            Text(reason).litterFont(.caption).foregroundStyle(LitterTheme.textMuted)
                        }
                    }
                }
                .accessibilityIdentifier("harness.setting.\(setting.key)")
                .disabled(loading)
                .listRowBackground(LitterTheme.surface)
            }
        }
        .litterFont(.body)
        .scrollContentBackground(.hidden)
        .background(LitterTheme.backgroundGradient)
        .navigationTitle(runtime.displayLabel)
        .searchable(text: $search, prompt: "Find a setting")
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let setting = editing {
                RuntimeSettingEditor(setting: setting) { value in
                    #if DEBUG
                    if HarnessSettingsUITestFixture.isEnabled {
                        // Exercise the real editor and read-back rendering with an
                        // isolated in-memory test transport, never a user's server.
                        _ = try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
                        settings = settings.map { original in
                            var updated = original
                            if updated.key == setting.key { updated.valueJson = value }
                            return updated
                        }
                        error = nil
                        return
                    }
                    #endif
                    let result = try await appModel.client.setRuntimeSetting(
                        serverId: serverId, runtimeKind: runtime, key: setting.key, valueJson: value)
                    settings = result.settings
                    error = nil
                    if setting.key == "$native" || setting.key.localizedCaseInsensitiveContains("model") || setting.key.localizedCaseInsensitiveContains("provider") {
                        let model = appModel
                        let savedServerId = serverId
                        Task { await model.loadAvailableModelsIfNeeded(serverId: savedServerId, force: true) }
                    }
                }
            }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        #if DEBUG
        if HarnessSettingsUITestFixture.isEnabled {
            settings = HarnessSettingsUITestFixture.settings
            return
        }
        #endif
        do {
            let result = try await appModel.client.runtimeSettings(serverId: serverId, runtimeKind: runtime)
            guard !Task.isCancelled else { return }
            settings = result.settings
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

private struct RuntimeSettingEditor: View {
    @Environment(\.dismiss) private var dismiss
    let setting: RuntimeSettingDescriptor
    let save: (String) async throws -> Void
    @State private var value: String
    @State private var saving = false
    @State private var error: String?

    init(setting: RuntimeSettingDescriptor, save: @escaping (String) async throws -> Void) {
        self.setting = setting
        self.save = save
        let string = setting.valueKind == .string
            ? (try? JSONDecoder().decode(String.self, from: Data(setting.valueJson.utf8))) : nil
        _value = State(initialValue: string ?? setting.valueJson)
    }

    // Choice values are strings even when an unset descriptor uses JSON/null.
    private func choiceValue(_ choice: String) -> String {
        guard setting.valueKind != .string else { return choice }
        return (try? String(decoding: JSONEncoder().encode(choice), as: UTF8.self)) ?? setting.valueJson
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(setting.label) {
                    if setting.valueKind == .boolean {
                        Toggle("Enabled", isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" }))
                    } else if !setting.choices.isEmpty {
                        Picker("Value", selection: $value) {
                            if !setting.choices.map(choiceValue).contains(value) { Text(value).tag(value) }
                            ForEach(setting.choices, id: \.self) { Text($0).tag(choiceValue($0)) }
                        }
                        .accessibilityIdentifier("harness.setting.choices")
                    } else {
                        TextField(setting.valueKind == .json ? "JSON value" : "Value", text: $value, axis: .vertical)
                            .lineLimit(3...20).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
                .disabled(!setting.writable || saving)
                Section("Source") {
                    Text(setting.source)
                    Text("Scope: \(setting.scope)")
                    if let reason = setting.readOnlyReason { Text(reason) }
                }
                if let error { Text(error).foregroundStyle(LitterTheme.danger) }
            }
            .litterFont(.body)
            .foregroundStyle(LitterTheme.textPrimary)
            .scrollContentBackground(.hidden)
            .background(LitterTheme.backgroundGradient)
            .navigationTitle("Edit setting")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                let json = setting.valueKind == .string
                                    ? String(decoding: try JSONEncoder().encode(value), as: UTF8.self) : value
                                try await save(json)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(!setting.writable || saving || value == setting.valueJson && setting.valueKind != .string)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

#if DEBUG
private enum HarnessSettingsUITestFixture {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-harness-settings")
    }

    static let settings: [RuntimeSettingDescriptor] = [
        RuntimeSettingDescriptor(key: "quietStartup", label: "Quiet startup", valueJson: "false", valueKind: .boolean,
            choices: [], scope: "user", source: "UI test fixture", writable: true, readOnlyReason: nil),
        RuntimeSettingDescriptor(key: "theme", label: "Theme", valueJson: "null", valueKind: .json,
            choices: ["dark", "light"], scope: "user override (unset)", source: "UI test fixture", writable: true, readOnlyReason: nil),
        RuntimeSettingDescriptor(key: "managedPolicy", label: "Managed policy", valueJson: "true", valueKind: .boolean,
            choices: [], scope: "managed", source: "UI test fixture", writable: false, readOnlyReason: "Managed by administrator"),
    ]
}
#endif
