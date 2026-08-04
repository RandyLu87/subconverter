import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case importedYAML

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importedYAML:
            return "Imported YAML"
        }
    }
}

enum SourceStatus: String, Codable {
    case idle
    case ready
    case error

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .ready:
            return "Ready"
        case .error:
            return "Error"
        }
    }
}

struct SourceItem: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var kind: SourceKind
    var value: String
    var enabled: Bool
    var order: Int
    var lastStatus: SourceStatus
    var lastError: String?

    init(
        id: UUID = UUID(),
        name: String,
        kind: SourceKind,
        value: String,
        enabled: Bool = true,
        order: Int,
        lastStatus: SourceStatus = .idle,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.value = value
        self.enabled = enabled
        self.order = order
        self.lastStatus = lastStatus
        self.lastError = lastError
    }

    var displayValue: String {
        URL(fileURLWithPath: value).lastPathComponent
    }
}

struct PersistedAppState: Codable {
    var sources: [SourceItem]
    var lastGeneratedAt: Date?
    var lastGeneratedProxyCount: Int?
    var customDirectRulesText: String
    /// 存「停用的」而不是「启用的」:以后版本往 PresetBuilder.policyGroups 里加新组时,
    /// 老 state.json 里没有这个名字,新组自动是启用的 —— 存启用列表就会反过来,
    /// 新组对老用户默默不生效。
    var disabledPolicyGroups: Set<String>

    init(
        sources: [SourceItem],
        lastGeneratedAt: Date?,
        lastGeneratedProxyCount: Int?,
        customDirectRulesText: String = "",
        disabledPolicyGroups: Set<String> = []
    ) {
        self.sources = sources
        self.lastGeneratedAt = lastGeneratedAt
        self.lastGeneratedProxyCount = lastGeneratedProxyCount
        self.customDirectRulesText = customDirectRulesText
        self.disabledPolicyGroups = disabledPolicyGroups
    }

    private enum CodingKeys: String, CodingKey {
        case sources
        case lastGeneratedAt
        case lastGeneratedProxyCount
        case customDirectRulesText
        case disabledPolicyGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSources = try container.decode([FailableSource].self, forKey: .sources)
        self.sources = rawSources.compactMap { $0.source }
        self.lastGeneratedAt = try container.decodeIfPresent(Date.self, forKey: .lastGeneratedAt)
        self.lastGeneratedProxyCount = try container.decodeIfPresent(Int.self, forKey: .lastGeneratedProxyCount)
        self.customDirectRulesText = try container.decodeIfPresent(String.self, forKey: .customDirectRulesText) ?? ""
        self.disabledPolicyGroups = try container.decodeIfPresent(Set<String>.self, forKey: .disabledPolicyGroups) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sources, forKey: .sources)
        try container.encodeIfPresent(lastGeneratedAt, forKey: .lastGeneratedAt)
        try container.encodeIfPresent(lastGeneratedProxyCount, forKey: .lastGeneratedProxyCount)
        try container.encode(customDirectRulesText, forKey: .customDirectRulesText)
        try container.encode(disabledPolicyGroups, forKey: .disabledPolicyGroups)
    }

    static let empty = PersistedAppState(sources: [], lastGeneratedAt: nil, lastGeneratedProxyCount: nil, customDirectRulesText: "")
}

/// Wraps SourceItem so a single bad entry (e.g. a legacy subscription-URL source
/// after that kind was removed) doesn't fail the whole state.json decode.
private struct FailableSource: Decodable {
    let source: SourceItem?

    init(from decoder: Decoder) throws {
        self.source = try? SourceItem(from: decoder)
    }
}
