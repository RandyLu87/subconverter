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
    private let prefetcher: SubscriptionPrefetcher

    init(
        runtimeInstaller: RuntimeInstaller = RuntimeInstaller(),
        engine: EngineController,
        presetBuilder: PresetBuilder = PresetBuilder(),
        postProcessor: YAMLPostProcessor = YAMLPostProcessor(),
        builder: ClashConfigBuilder = ClashConfigBuilder(),
        prefetcher: SubscriptionPrefetcher = SubscriptionPrefetcher()
    ) {
        self.runtimeInstaller = runtimeInstaller
        self.engine = engine
        self.presetBuilder = presetBuilder
        self.postProcessor = postProcessor
        self.builder = builder
        self.prefetcher = prefetcher
    }

    func prepareRuntime() throws -> RuntimeContext {
        try runtimeInstaller.installIfNeeded()
    }

    func generate(from sources: [SourceItem], customDirectRulesText: String) async throws -> GenerationResult {
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
        let resolvedSourceValues = await resolveSourceValues(enabledSources)
        let payload = try await engine.fetchProxyList(
            for: resolvedSourceValues,
            configPath: "presets/current.toml"
        )

        let parsed = try ProxyListParser.parse(payload)
        AppLogger.log("Parsed \(parsed.count) proxy entry(ies) from merged payload.")
        let normalized = postProcessor.deduplicateAndNormalize(parsed)
        AppLogger.log("Normalized proxy count after deduplication: \(normalized.count).")
        AppLogger.log(
            "Normalized country buckets: \(ProxyCountryClassifier.summary(for: ProxyCountryClassifier.bucketed(names: normalized.map { $0.name })))"
        )
        let rules = try presetBuilder.loadRuleLines(
            from: runtime.appRulesDirectory,
            customDirectRulesText: customDirectRulesText
        )
        AppLogger.log("Loaded \(rules.count) rule lines.")
        let yaml = builder.build(proxies: normalized, ruleLines: rules)
        AppLogger.log("Final YAML size: \(yaml.utf8.count) bytes.")

        return GenerationResult(yaml: yaml, proxyCount: normalized.count)
    }

    /// Prefetches subscription URLs locally so the engine reads a Clash-friendly file
    /// instead of hitting the upstream itself. Falls back to the raw URL if prefetch
    /// fails so the engine still gets a chance to handle it directly.
    private func resolveSourceValues(_ sources: [SourceItem]) async -> [String] {
        var resolved: [String] = []
        for source in sources {
            switch source.kind {
            case .subscriptionURL:
                do {
                    let path = try await prefetcher.prefetch(
                        urlString: source.value,
                        sourceID: source.id
                    )
                    AppLogger.log("Prefetched subscription \(source.name) to \(path).")
                    resolved.append(path)
                } catch {
                    AppLogger.log(
                        "Prefetch failed for \(source.name) (\(error.localizedDescription)); falling back to raw URL."
                    )
                    resolved.append(source.value)
                }
            case .importedYAML:
                resolved.append(source.value)
            }
        }
        return resolved
    }
}
