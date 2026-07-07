import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum AppMode: Hashable {
    case generate
    case convert
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var sources: [SourceItem]
    @Published var previewText = ""
    @Published var isGenerating = false
    @Published var statusMessage = "Ready"
    @Published var lastGeneratedAt: Date?
    @Published var lastGeneratedProxyCount: Int?
    @Published var customDirectRulesText = ""

    // Clash → sing-box 转换
    @Published var appMode: AppMode = .generate
    @Published var conversionInput = ""
    @Published var conversionOutput = ""
    @Published var conversionIconsJSON: String?
    @Published var conversionMessages: [ConversionMessage] = []
    @Published var isConverting = false

    private let store = AppStateStore()
    private let engine = EngineController()
    private lazy var generator = ConfigGenerationService(engine: engine)
    private lazy var importer = SourceImportService(engine: engine)
    private lazy var converter = ClashToSingBoxConverter(engine: engine)

    private init() {
        let state = store.load()
        self.sources = state.sources.sorted(by: { $0.order < $1.order })
        self.lastGeneratedAt = state.lastGeneratedAt
        self.lastGeneratedProxyCount = state.lastGeneratedProxyCount
        self.customDirectRulesText = state.customDirectRulesText
    }

    var sortedSources: [SourceItem] {
        sources.sorted(by: { $0.order < $1.order })
    }

    var canGenerate: Bool {
        sortedSources.contains(where: \.enabled)
    }

    func removeSource(_ source: SourceItem) {
        sources.removeAll { $0.id == source.id }
        normalizeOrders()
        persist()
    }

    func moveSource(_ source: SourceItem, offset: Int) {
        let ordered = sortedSources
        guard let index = ordered.firstIndex(where: { $0.id == source.id }) else {
            return
        }
        let targetIndex = index + offset
        guard ordered.indices.contains(targetIndex) else {
            return
        }

        var mutable = ordered
        mutable.swapAt(index, targetIndex)
        sources = mutable.enumerated().map { index, item in
            var item = item
            item.order = index
            return item
        }
        persist()
    }

    func updateSource(_ source: SourceItem) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else {
            return
        }
        sources[index] = source
        persist()
    }

    func openImportPanel() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.yaml, .text]
        panel.message = "Import a Clash/Mihomo YAML file containing proxies."

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let source = try await importer.importYAML(from: url, order: nextOrder())
            sources.append(source)
            normalizeOrders()
            persist()
            statusMessage = "Imported \(url.lastPathComponent)."
            AppLogger.log("Import succeeded for \(url.lastPathComponent).")
        } catch {
            statusMessage = error.localizedDescription
            AppLogger.log("Import panel flow failed: \(error.localizedDescription)")
        }
    }

    func generate() async {
        guard !isGenerating else {
            return
        }

        isGenerating = true
        statusMessage = "Generating..."
        AppLogger.log("Generate button pressed with \(sortedSources.filter(\.enabled).count) enabled source(s).")
        defer { isGenerating = false }

        do {
            let result = try await generator.generate(
                from: sortedSources,
                customDirectRulesText: customDirectRulesText
            )
            previewText = result.yaml
            lastGeneratedAt = Date()
            lastGeneratedProxyCount = result.proxyCount
            markReadySources()
            persist()
            statusMessage = "Generated \(result.proxyCount) proxies."
            AppLogger.log("Generate succeeded with \(result.proxyCount) proxies.")
        } catch {
            markFailedSources(error.localizedDescription)
            persist()
            statusMessage = error.localizedDescription
            AppLogger.log("Generate failed: \(error.localizedDescription)")
        }
    }

    func exportPreview() {
        guard !previewText.isEmpty else {
            statusMessage = "Generate a configuration before exporting."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.yaml]
        panel.nameFieldStringValue = "subconfig-clash.yaml"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try previewText.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported to \(url.lastPathComponent)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Clash → sing-box 转换

    func importClashForConversion() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.yaml, .text]
        panel.message = "选择要转换为 sing-box 的 Clash / Mihomo YAML 配置。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            conversionInput = try String(contentsOf: url, encoding: .utf8)
            statusMessage = "已载入 \(url.lastPathComponent)。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func convert() async {
        guard !isConverting else { return }
        guard !conversionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请先导入或粘贴 Clash 配置。"
            return
        }
        isConverting = true
        statusMessage = "转换中..."
        defer { isConverting = false }
        do {
            let output = try await converter.convert(clashYAML: conversionInput)
            conversionOutput = output.configJSON
            conversionIconsJSON = output.iconsJSON
            conversionMessages = output.report.messages
            statusMessage = output.report.hasError ? "转换完成(含警告/错误)。" : "转换完成。"
            AppLogger.log("Clash→sing-box conversion done.")
        } catch {
            conversionMessages = [ConversionMessage(level: .error, text: error.localizedDescription)]
            statusMessage = error.localizedDescription
            AppLogger.log("Clash→sing-box conversion failed: \(error.localizedDescription)")
        }
    }

    func exportConversion() {
        guard !conversionOutput.isEmpty else {
            statusMessage = "请先转换再导出。"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try conversionOutput.write(to: url, atomically: true, encoding: .utf8)
            if let icons = conversionIconsJSON {
                let iconsURL = url.deletingLastPathComponent().appendingPathComponent("icons.json")
                try icons.write(to: iconsURL, atomically: true, encoding: .utf8)
                statusMessage = "已导出 \(url.lastPathComponent) + icons.json。"
            } else {
                statusMessage = "已导出 \(url.lastPathComponent)。"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func shutdown() {
        engine.stop()
    }

    func updateCustomDirectRulesText(_ value: String) {
        customDirectRulesText = value
        persist()
    }

    private func nextOrder() -> Int {
        (sources.map(\.order).max() ?? -1) + 1
    }

    private func normalizeOrders() {
        sources = sortedSources.enumerated().map { index, item in
            var item = item
            item.order = index
            return item
        }
    }

    private func markReadySources() {
        sources = sources.map { item in
            var item = item
            if item.enabled {
                item.lastStatus = .ready
                item.lastError = nil
            }
            return item
        }
    }

    private func markFailedSources(_ message: String) {
        let matchedIDs = Set(
            sources.compactMap { item -> UUID? in
                guard item.enabled else {
                    return nil
                }

                if message.contains(item.value) || message.contains(item.displayValue) || message.contains(item.name) {
                    return item.id
                }

                return nil
            }
        )

        sources = sources.map { item in
            guard item.enabled else {
                return item
            }

            if !matchedIDs.isEmpty && !matchedIDs.contains(item.id) {
                return item
            }

            var item = item
            item.lastStatus = .error
            item.lastError = message
            return item
        }
    }

    private func persist() {
        store.save(
            PersistedAppState(
                sources: sortedSources,
                lastGeneratedAt: lastGeneratedAt,
                lastGeneratedProxyCount: lastGeneratedProxyCount,
                customDirectRulesText: customDirectRulesText
            )
        )
    }
}
