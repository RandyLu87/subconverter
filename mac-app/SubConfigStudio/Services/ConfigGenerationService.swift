import Foundation

struct GenerationResult {
    var yaml: String
    var proxyCount: Int
}

final class ConfigGenerationService {
    private let runtimeInstaller: RuntimeInstaller
    private let engine: EngineController
    private let presetBuilder: PresetBuilder
    private let postProcessor: YAMLPostProcessor
    private let builder: ClashConfigBuilder

    init(
        runtimeInstaller: RuntimeInstaller = RuntimeInstaller(),
        engine: EngineController,
        presetBuilder: PresetBuilder = PresetBuilder(),
        postProcessor: YAMLPostProcessor = YAMLPostProcessor(),
        builder: ClashConfigBuilder = ClashConfigBuilder()
    ) {
        self.runtimeInstaller = runtimeInstaller
        self.engine = engine
        self.presetBuilder = presetBuilder
        self.postProcessor = postProcessor
        self.builder = builder
    }

    func prepareRuntime() throws -> RuntimeContext {
        try runtimeInstaller.installIfNeeded()
    }

    func generate(from sources: [SourceItem]) async throws -> GenerationResult {
        let enabledSources = sources
            .filter(\.enabled)
            .sorted { $0.order < $1.order }

        guard !enabledSources.isEmpty else {
            throw EngineError.noSources
        }
        AppLogger.log("Generation started for \(enabledSources.count) enabled source(s).")

        let runtime = try prepareRuntime()
        let configURL = runtime.presetsDirectory.appendingPathComponent("current.toml")
        try presetBuilder.buildExternalConfig(at: configURL)

        try await engine.start(using: runtime)
        let payload = try await engine.fetchProxyList(
            for: enabledSources.map(\.value),
            configPath: "presets/current.toml"
        )

        let parsed = try ProxyListParser.parse(payload)
        AppLogger.log("Parsed \(parsed.count) proxy entry(ies) from merged payload.")
        let normalized = postProcessor.deduplicateAndNormalize(parsed)
        AppLogger.log("Normalized proxy count after deduplication: \(normalized.count).")
        AppLogger.log(
            "Normalized country buckets: \(ProxyCountryClassifier.summary(for: ProxyCountryClassifier.bucketed(names: normalized.map { $0.name })))"
        )
        let rules = try presetBuilder.loadRuleLines(from: runtime.appRulesDirectory)
        AppLogger.log("Loaded \(rules.count) rule lines.")
        let yaml = builder.build(proxies: normalized, ruleLines: rules)
        AppLogger.log("Final YAML size: \(yaml.utf8.count) bytes.")

        return GenerationResult(yaml: yaml, proxyCount: normalized.count)
    }
}
