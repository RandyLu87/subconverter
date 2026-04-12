import Foundation

final class SourceImportService {
    private let runtimeInstaller: RuntimeInstaller
    private let engine: EngineController

    init(runtimeInstaller: RuntimeInstaller = RuntimeInstaller(), engine: EngineController) {
        self.runtimeInstaller = runtimeInstaller
        self.engine = engine
    }

    func importYAML(from fileURL: URL, order: Int) async throws -> SourceItem {
        try AppPaths.ensureDirectories()
        AppLogger.log("Import requested for YAML file \(fileURL.path).")

        let targetURL = AppPaths.importsDirectory.appendingPathComponent("\(UUID().uuidString)-\(fileURL.lastPathComponent)")
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.copyItem(at: fileURL, to: targetURL)

        do {
            let runtime = try runtimeInstaller.installIfNeeded()
            let presetURL = runtime.presetsDirectory.appendingPathComponent("current.toml")
            try PresetBuilder().buildExternalConfig(at: presetURL)
            try await engine.start(using: runtime)
            let response = try await engine.fetchProxyList(
                for: [targetURL.path],
                configPath: "presets/current.toml"
            )
            let proxies = try ProxyListParser.parse(response)
            AppLogger.log("Imported YAML validated with \(proxies.count) proxy entrie(s).")
        } catch {
            AppLogger.log("Import failed for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: targetURL)
            throw SourceImportError.invalidYAML(error.localizedDescription)
        }

        return SourceItem(
            name: fileURL.deletingPathExtension().lastPathComponent,
            kind: .importedYAML,
            value: targetURL.path,
            enabled: true,
            order: order,
            lastStatus: .ready
        )
    }
}

enum SourceImportError: LocalizedError {
    case invalidYAML(String)

    var errorDescription: String? {
        switch self {
        case .invalidYAML(let details):
            return "Imported YAML does not contain valid Clash proxies. \(details)"
        }
    }
}
