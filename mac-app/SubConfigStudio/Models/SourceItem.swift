import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case subscriptionURL
    case importedYAML

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subscriptionURL:
            return "Subscription URL"
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
        if kind == .subscriptionURL {
            return value
        }

        return URL(fileURLWithPath: value).lastPathComponent
    }
}

struct PersistedAppState: Codable {
    var sources: [SourceItem]
    var lastGeneratedAt: Date?
    var lastGeneratedProxyCount: Int?
    var customDirectRulesText: String

    init(
        sources: [SourceItem],
        lastGeneratedAt: Date?,
        lastGeneratedProxyCount: Int?,
        customDirectRulesText: String = ""
    ) {
        self.sources = sources
        self.lastGeneratedAt = lastGeneratedAt
        self.lastGeneratedProxyCount = lastGeneratedProxyCount
        self.customDirectRulesText = customDirectRulesText
    }

    private enum CodingKeys: String, CodingKey {
        case sources
        case lastGeneratedAt
        case lastGeneratedProxyCount
        case customDirectRulesText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sources = try container.decode([SourceItem].self, forKey: .sources)
        self.lastGeneratedAt = try container.decodeIfPresent(Date.self, forKey: .lastGeneratedAt)
        self.lastGeneratedProxyCount = try container.decodeIfPresent(Int.self, forKey: .lastGeneratedProxyCount)
        self.customDirectRulesText = try container.decodeIfPresent(String.self, forKey: .customDirectRulesText) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sources, forKey: .sources)
        try container.encodeIfPresent(lastGeneratedAt, forKey: .lastGeneratedAt)
        try container.encodeIfPresent(lastGeneratedProxyCount, forKey: .lastGeneratedProxyCount)
        try container.encode(customDirectRulesText, forKey: .customDirectRulesText)
    }

    static let empty = PersistedAppState(sources: [], lastGeneratedAt: nil, lastGeneratedProxyCount: nil, customDirectRulesText: "")
}
