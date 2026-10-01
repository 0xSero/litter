import XCTest
@testable import Litter

@MainActor
final class ModelPickerCatalogTests: XCTestCase {
    private func model(
        _ id: String,
        runtime: String,
        kind: ModelEntryKind = .model,
        name: String? = nil,
        provider: String? = nil,
        providerLabel: String? = nil,
        hidden: Bool = false
    ) -> ModelInfo {
        ModelInfo(
            id: id,
            model: id,
            displayName: name ?? id,
            description: "",
            hidden: hidden,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: .medium,
            inputModalities: [],
            isDefault: false,
            agentRuntimeKind: runtime,
            providerId: provider,
            entryKind: kind,
            pickerName: name ?? id,
            providerLabel: providerLabel
        )
    }

    func testModesAreSeparatedFromModelsAndProvidersAreGrouped() throws {
        let catalog = ModelPickerCatalog(models: [
            model("amp/high", runtime: "amp", kind: .mode, name: "high"),
            model("glm-5.2", runtime: "amp", kind: .pluginMode),
            model("openai/gpt-6", runtime: "pi", name: "gpt-6", provider: "openai", providerLabel: "OpenAI"),
            model("x-ai/grok-5", runtime: "pi", name: "grok-5", provider: "x-ai", providerLabel: "xAI"),
            model("local", runtime: "pi"),
            model("secret", runtime: "pi", hidden: true),
        ])

        let amp = try XCTUnwrap(catalog.harness("amp"))
        XCTAssertEqual(amp.modes.map(\.id), ["amp/high"])
        XCTAssertEqual(amp.pluginModes.map(\.id), ["glm-5.2"])
        XCTAssertEqual(amp.modelCount, 0)
        XCTAssertEqual(amp.summary, "1 mode · 1 plugin mode")

        let pi = try XCTUnwrap(catalog.harness("pi"))
        XCTAssertEqual(pi.modelCount, 3, "hidden entries are not listed")
        XCTAssertEqual(pi.providers.map(\.title), [nil, "OpenAI", "xAI"])
        XCTAssertEqual(pi.summary, "3 models · 2 providers")
    }

    func testSearchMatchesEveryTokenAcrossHarnessAndProvider() {
        let catalog = ModelPickerCatalog(models: [
            model("openai/gpt-6", runtime: "pi", name: "gpt-6", provider: "openai", providerLabel: "OpenAI"),
            model("gpt-6", runtime: "codex"),
            model("anthropic/sonnet", runtime: "pi", name: "sonnet", provider: "anthropic", providerLabel: "Anthropic"),
        ])

        let all = catalog.search("gpt")
        XCTAssertEqual(all.total, 2)

        let scoped = catalog.search("openai gpt")
        XCTAssertEqual(scoped.total, 1)
        XCTAssertEqual(scoped.sections.first?.models.first?.id, "openai/gpt-6")

        XCTAssertEqual(catalog.search("gpt", in: "codex").total, 1)
        XCTAssertEqual(catalog.search("   ").total, 0)
    }

    func testSearchCapsShownResultsButCountsAll() {
        let models = (0..<400).map { model("m\($0)", runtime: "devin") }
        let results = ModelPickerCatalog(models: models).search("m")
        XCTAssertEqual(results.total, 400)
        XCTAssertEqual(results.shown, ModelPickerCatalog.searchLimit)
    }

    func testRecentsKeepMostRecentFirstWithoutDuplicates() {
        let a = model("a", runtime: "codex")
        let b = model("b", runtime: "pi")
        var raw = ModelPickerRecents.recording(a, in: "")
        raw = ModelPickerRecents.recording(b, in: raw)
        raw = ModelPickerRecents.recording(a, in: raw)
        XCTAssertEqual(ModelPickerRecents.decode(raw), ["codex:a", "pi:b"])
    }

    func testDisplayNameUsesModeName() {
        XCTAssertEqual(modelPickerDisplayName(model("amp/high", runtime: "amp", kind: .mode, name: "high")), "high")
        XCTAssertEqual(modelPickerDisplayName(model("gpt-6", runtime: "codex", name: "GPT-6")), "GPT-6")
    }
}
